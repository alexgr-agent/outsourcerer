# Factory: `plan run` and `flow` (scheduler + flows)

Source: `scripts/factory-flow.sh`. Tests: `scripts/tests/test_factory_flow.sh`.

## `plan run [plan] [--max-parallel N] [--once] [--interval S] [--auto-land] [--max-minutes M] [--setup CMD]`

Drives a plan until it is finished or needs you. Each pass ("tick") does two things:

1. **Check running work.** For each running task, read its job the same way `wait` does.
   - Claimed but no job recorded yet: a launch is in flight, so it is left alone (never started twice) for
     `OSRC_FACTORY_LAUNCH_GRACE` seconds (default 300). After that, a job whose `task_ref` names the task is adopted
     (its launcher stopped before recording it); with none, it counts as a failed attempt ("never launched").
   - A job that never got a worker (no status, or launching/running with no process) for `OSRC_FACTORY_JOB_STALE_SECS`
     (default 900) counts as failed, so nothing waits forever.
   - Job finished well: the pass that moves the task running -> verifying runs the done check (`land`'s done
     contract); a task someone else is checking (a `task done`, another driver) is left to them unless that checker
     is gone or its claim is older than `OSRC_FACTORY_VERIFY_STALE_SECS` (default 900). Pass = done. Fail = counts as a failed attempt.
   - Job failed (or its worker died): if attempts remain (`retries`, default 1), the task is reset the way
     `task retry` does it and `.result` becomes "previous attempt failed because ...", which the next brief shows
     under "Earlier attempt". Otherwise the task is failed with the reason (the task store wakes the heartbeat).
   - Job blocked (worker needs input): the task is held for you, with a wake event and the exact command
     (`task release tX --answer "..." --plan p`; a new worker starts with your answer).
   - A captain's decision or a land step found running a worker (someone ran `task start` on it) is held: a
     worker's output never completes a decision or a land.
2. **Start ready work**, up to `--max-parallel` (default 3) at once, counting what is already running.
   - A launch failure counts as a failed attempt and is retried within the task's `retries`.
   - Model: a flow task keeps its stage's model list (`fallback`). At dispatch a model now on the exclude list is
     skipped for the next allowed one; each retry moves to the next allowed model.
   - A decision or land that finishes in a pass frees its dependents in the same pass.
   - Past `--max-minutes`, no new check, land or launch starts.

After each pass it prints one line with the four buckets:
`[plan tick 3] Captain's Call: 1 (t4) | Landed/Done: 2 | Underway: 1 (t3) | Next: 1 ready (t5), 2 waiting`

It stops with one plain line saying why:

| exit | meaning |
|---|---|
| 0 | everything is done (or the plan has no tasks) |
| 3 | needs you: something is held or failed and nothing else can move (the line lists held, failed, and what waits on what) |
| 2 | time cap (`--max-minutes`, default 240) reached; running jobs keep going, run `plan run` again to resume |
| 124 | `--once` finished its single pass with work still underway |
| 4 | another `plan run` is already driving this plan (nothing was done) |
| 1 | error |

- `--once`: one pass, for the heartbeat or an orchestrator turn.
- `--auto-land`: land each plain build (ship) task through the merge gate as soon as it is done. Builds made by a
  flow are never auto-landed: the flow's own land stage lands them after their review (council-build), or the
  captain lands the winner after the pick (best-of-n). A failed auto-land never undoes the build: it stays done,
  the reason goes in `land_error`, a wake is sent, and the stop line lists `land tX --plan p`.
- `--setup CMD`: the default command `land` runs in the clean merged checkout before the check (for example
  `npm ci`). A land stage's own `setup`, then the build task's `setup`, win over it. Passed only to a `land` that
  supports `--setup`. A failed land never changes the build's state from here: if `land` holds it (merge
  conflict), it stays held with land's reason.
- Only one `plan run` can drive a plan at a time (lock at `plans/<plan>/run.lock`). A lock left by a crashed run is
  taken over automatically, under a second guard lock and only if its owner record is unchanged, so a slow taker
  never removes a fresh lock. A run that cannot record itself as the owner (disk full) refuses to start.
- Ctrl-C / SIGTERM stop at once (the wait between passes is interruptible), release the lock and put back the
  caller's own INT/TERM traps. Running jobs keep going.
- Wake events: task held and task failed come from the task store on the state change (one each, never doubled);
  `plan run` adds "plan finished" (once per finished state, not every pass).

## `flow ls | show <name> | run <name> [--plan p] [--var k=v ...] [--repo path] [--dry-run]`

A flow is a reusable recipe of tasks. `flow run` turns it into tasks in a plan, then you run `plan run <plan>`.

- `--plan`: plan to add to; created if missing. Default: a new plan named `<flow>-<date>-<time>`
  (it becomes the current plan if there is none).
- With no `--plan`, the generated name is always a new plan (`-2`, `-3`... if two runs share a second).
- `--repo`: git repo for build tasks (default: the repo you are in). A flow that builds code refuses to run without one.
  Adding to an existing plan with a different `--repo` is refused.
- All or nothing: the flow is validated and expanded in full first; if adding a task fails part way, the tasks this
  run added (or the plan it created) are removed.
- `--var k=v`: fill a flow variable. Missing required vars and unknown names (typos) are refused before anything is written.
  Values are inserted as plain text: quotes, `$( )` and backticks are never run. (The `check` var IS a shell
  command by design: the done check runs it in the task's worktree.)
- `--dry-run`: show the tasks it would add, write nothing.

Built-in flows (`references/flows/`); your own in `$OSRC_HOME/flows/<name>.json` override them by name:

| flow | stages |
|---|---|
| `council-build` (`--var setup=...` for land) | two advisors on different frontier families (sol, opus) -> synthesize (opus) -> build (glm-5-2, then swe-1-7, kimi-k3) with `check` -> fidelity review (sol, must say VERDICT: PASS) -> land |
| `spec-build` | spec (opus) -> plan (sol) -> build (glm-5-2...) -> verify against the spec (sol, VERDICT) |
| `best-of-n` | `--var n=3` candidates built in parallel on different models -> compare (sol) -> captain picks |

Models respect the exclude list: a stage tries its model, then its fallbacks, skipping excluded ones. If all are
excluded the task gets no model and the router picks (which also respects the list).

## Flow file schema

```json
{"name": "x", "description": "...",
 "vars": {"goal": "required", "check": "optional", "n": {"default": "3"}},
 "stages": [
   {"id": "build", "title": "Build {{goal}}", "shape": "ship", "verb": "edit", "deps": ["plan"],
    "model": "glm-5-2", "fallback": ["swe-1-7"], "check": "{{check}}", "setup": "npm ci", "prompt": "...", "retries": 1},
   {"id": "cand", "repeat": "{{n}}", "models": ["glm-5-2", "swe-1-7"], "prompt": "candidate {{i}} of {{n}}", "shape": "ship", "verb": "edit"},
   {"id": "review", "deps": ["build"], "verdict": true, "model": "sol", "prompt": "... end with VERDICT: PASS or VERDICT: FAIL - why"},
   {"id": "decide", "deps": ["review"], "hold": true, "title": "Captain decides"},
   {"id": "land", "land": "build", "deps": ["review"]}
 ]}
```

- `deps` name earlier stages only (no cycles). A dep on a repeated stage means every copy.
- `repeat` (1-10) makes copies `<id>-1..N`; `{{i}}` is the copy number, `{{n}}` the count; `models` rotates per copy.
- `hold: true`: a decision for the captain. Created as todo with `hold_after_deps: true`; once its deps are done the
  scheduler holds it and wakes you. Answer with `task release <tid> --answer "<decision>"`. With no prompt it is a pure gate
  (stored as `gate: true`): it completes with your answer as its result (`task release --done` closes it at once). With a prompt, a worker runs with your answer in its brief.
- `verdict: true`: a reviewer. The LAST non-empty line of its job's `last.txt` must be exactly `VERDICT: PASS` or
  `VERDICT: FAIL - <reason>` (no markup; `out.log` is never read). Anything else (no verdict, a fenced or quoted
  verdict, an echoed template, a PASS that also says FAIL, a PASS after an earlier FAIL line) holds the reviewer for you.
  - FAIL: the build it reviewed (its one ship dependency) goes back in line with the reviewer's reason in its brief
    (and its previous branch to start from), counted against that build's `retries`; then the review runs again.
  - Budget used up (or no single build to redo): the reviewer is held with the commands:
    accept anyway `task done tV --force --plan p`, one more redo `task release tV --answer "<what to fix>" --plan p`
    (your answer goes into the build's brief), or stop `task cancel tV --plan p`.
- `land: "<stage>"`: no worker runs; when its deps are done the scheduler lands that stage's task through `land`.
  The target must be one non-repeated build (ship) stage, landed by only this stage. Each try is counted
  (`land_attempts`); a failed land holds the stage with the commands (`task release tL --answer "land again"`, or land
  by hand and `task done tL --force`). A land interrupted mid-way is tried again up to `retries + 1` times, then held.

Validation fails closed: a stage that is not an object, deps that are not a list, a non-text prompt/model/check, a
bad `retries` (0-10), a land stage that also holds/reviews/repeats, a hold+verdict stage with no prompt, or a flow
file the checker cannot read are all refused before anything is written.

## Fleet view

`bearings` and `rundown` add one line per active plan:
`plan p: 1 need you · 2 done · 1 underway · 3 next (1 ready)`. Finished plans are not shown (one jq pass over
all active plans; a plan whose finished marker is newer than its tasks is not even read).

## Extra task fields (written by flows, kept by the task store)

`hold_after_deps`, `gate`, `land_target`, `require_verdict`, `fallback`, plus the scheduler's own bookkeeping
(`verdict_failed`, `prompt_orig`, `attempt_base`, `land_attempts`, `land_started_at`, `land_error`, `verifying_at`,
`verifying_pid`); it reads the task store's `claimed_at` and `launch_failed` when present. Tasks are created through the task store's
`_task_new`, in stage order (deps always exist first). See the header of `factory-flow.sh`.
