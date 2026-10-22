# Factory: `plan run` and `flow` (scheduler + flows)

Source: `scripts/factory-flow.sh`. Tests: `scripts/tests/test_factory_flow.sh`.

## `plan run [plan] [--max-parallel N] [--once] [--interval S] [--auto-land] [--max-minutes M]`

Drives a plan until it is finished or needs you. Each pass ("tick") does two things:

1. **Check running work.** For each running task, read its job the same way `wait` does.
   - Job finished well: the done check (`land`'s done contract) decides. Pass = done. Fail = counts as a failed attempt.
   - Job failed (or its worker died): if attempts remain (`retries`, default 1), the task is reset the way
     `task retry` does it and `.result` becomes "previous attempt failed because ...", which the next brief shows
     under "Earlier attempt". Otherwise the task is failed with the reason (the task store wakes the heartbeat).
   - Job blocked (worker needs input): the task is held for you, with a wake event.
2. **Start ready work**, up to `--max-parallel` (default 3) at once, counting what is already running.

After each pass it prints one line with the four buckets:
`[plan tick 3] Captain's Call: 1 (t4) | Landed/Done: 2 | Underway: 1 (t3) | Next: 1 ready (t5), 2 waiting`

It stops with one plain line saying why:

| exit | meaning |
|---|---|
| 0 | everything is done (or the plan has no tasks) |
| 3 | needs you: something is held or failed and nothing else can move (the line lists held, failed, and what waits on what) |
| 2 | time cap (`--max-minutes`, default 240) reached; running jobs keep going, run `plan run` again to resume |
| 124 | `--once` finished its single pass with work still underway |
| 1 | error, or another `plan run` is already driving this plan |

- `--once`: one pass, for the heartbeat or an orchestrator turn.
- `--auto-land`: land each build (ship) task through the merge gate as soon as it is done. A task that a flow's land
  stage owns is left to that stage, so the review runs first.
- Only one `plan run` can drive a plan at a time (lock at `plans/<plan>/run.lock`). A lock left by a crashed run is
  taken over automatically.
- Wake events: task held and task failed come from the task store on the state change (one each, never doubled);
  `plan run` adds "plan finished" (once per finished state, not every pass).

## `flow ls | show <name> | run <name> [--plan p] [--var k=v ...] [--repo path] [--dry-run]`

A flow is a reusable recipe of tasks. `flow run` turns it into tasks in a plan, then you run `plan run <plan>`.

- `--plan`: plan to add to; created if missing. Default: a new plan named `<flow>-<date>-<time>`
  (it becomes the current plan if there is none).
- `--repo`: git repo for build tasks (default: the repo you are in). A flow that builds code refuses to run without one.
- `--var k=v`: fill a flow variable. Missing required vars and unknown names (typos) are refused before anything is written.
  Values are inserted as plain text: quotes, `$( )` and backticks are never run. (The `check` var IS a shell
  command by design: the done check runs it in the task's worktree.)
- `--dry-run`: show the tasks it would add, write nothing.

Built-in flows (`references/flows/`); your own in `$OSRC_HOME/flows/<name>.json` override them by name:

| flow | stages |
|---|---|
| `council-build` | two advisors on different frontier families (sol, opus) -> synthesize (opus) -> build (glm-5-2, then swe-1-7, kimi-k3) with `check` -> fidelity review (sol, must say VERDICT: PASS) -> land |
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
    "model": "glm-5-2", "fallback": ["swe-1-7"], "check": "{{check}}", "prompt": "...", "retries": 1},
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
- `verdict: true`: the task's output must contain `VERDICT: PASS`. FAIL or no verdict holds it for you (read the
  report, then `task done` to accept, or retry the work it reviewed).
- `land: "<stage>"`: no worker runs; when its deps are done the scheduler lands that stage's task through `land`.

## Fleet view

`bearings` and `rundown` add one line per active plan:
`plan p: 1 need you · 2 done · 1 underway · 3 next (1 ready)`. Finished plans are not shown.

## Extra task fields (written by flows, kept by the task store)

`hold_after_deps`, `gate`, `land_target`, `require_verdict`. Tasks are created through the task store's
`_task_new`, in stage order (deps always exist first). See the header of `factory-flow.sh`.
