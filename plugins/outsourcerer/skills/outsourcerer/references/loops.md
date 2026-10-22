# Loops: bounded delegation cycles

A loop = **act → verify (external) → repeat until done or a cap fires.** Every loop ends in exactly one
honest state: `success` · `blocked` · `max_turns` · `max_time`. State lives on disk under
`~/.outsourcerer/loops/<id>/`. No loop runs unattended-infinite. Verification is external to the model
that did the work: tests, lint, or build are ideal, a second model is the fallback, and the model's own
"I'm done" is never enough on its own.

## Contents

- Which loop is this?
- `loop verify` (built in)
- `loop escalate` (built in)
- `loop resume` (built in)
- Recipes you drive: sweep, best-of-N, evaluator-optimizer, council-build
- Safety checklist

## Which loop is this? (pick before you build anything)

Two questions decide it. Answer them in order.

**1. Can a machine tell you it worked?** A test suite, a linter, a build, a schema check, an exit code.

**2. Do you know how much work there is?**

| Machine can verify? | Amount of work | Use | Why |
|---|---|---|---|
| Yes | Known, one target | **`loop verify`** (built in) | The check is the judge. Delegate, run it, feed failures back. |
| Yes, and cost matters most | Known, one target | **`loop escalate`** (built in) | Start on a budget model; pay for a stronger tier only when the check keeps failing. |
| Yes | Unknown / open-ended | **sweep** (until-dry) | You cannot set a sensible `--max` when you do not know how many there are; stop when rounds stop finding anything. |
| No, but you can compare | Small | **best-of-N** | No oracle, but you can look at five and know which is best. |
| No, and quality is a matter of degree | Any | **evaluator-optimizer** | "Correct" is not binary. Score against a rubric and iterate on the score. |
| Not yet: the plan is the risky part | Large | **council-build** | The expensive mistake is building the wrong thing well. Argue it out first, then use `loop verify` for the build step. |

Two rules override the table:

- **If nothing can verify it, do not loop.** A loop with no external check is a model marking its own
  homework in a circle. Use a single delegation and read the result yourself.
- **If a human must decide mid-way, do not loop.** Loops are for work you would otherwise babysit.
  Anything needing a judgement call belongs in `session`, where you can steer it live, or in a factory
  plan with a held task (`references/factory.md`).

Cheapest correct answer wins: most real work is `loop verify`, because most real work has tests.

## `loop verify` (built in)

The mechanical 90% case: delegate, run a real check, retry with the failure fed back, on the cheapest
model. You (the orchestrator) only re-enter on `blocked` or when a cap fires.

```
outsourcerer loop verify -m glm --check "npm test" [--max N] [--max-minutes M] [--verb edit|yolo] [--worktree] "make the auth tests pass"
```

- Each attempt delegates the task (mutating verb, default `edit`) with the last check output appended as
  feedback, then runs `--check`. `--check` is required.
- **Stall guard**: the identical check failure twice → `blocked` (not converging, so it surfaces instead
  of burning the budget). A delegate emitting `OSRC::BLOCKED` → `blocked`.
- Exit codes: 0 success · 2 `max_turns` or `max_time` · 3 blocked. Attempts and check output are saved
  under `~/.outsourcerer/loops/<id>/`.
- **`--worktree`** runs the loop in its own disposable git worktree and runs the check inside that same
  tree, so a bad attempt never touches the user's checkout. Use it for build loops on a repo the user
  is working in. Without it, the loop edits the tree it is run in.
- **Bounds, in order of what actually stops the loop.** The goal is `--check` passing; everything else is
  a runaway guard that only fires when the work is not converging:
  1. `--check` exits 0 → `success`. This is the real terminating condition.
  2. Same check failure twice → `blocked`.
  3. `--max-minutes` → `max_time`. Checked between attempts, so a run in progress is never abandoned
     half-done. Prefer this for open-ended work: three attempts at a one-line fix and three at a
     refactor are not comparable amounts of work, so a round count is a poor bound on its own.
  4. `--max` attempts (default 6, `OSRC_LOOP_MAX`) → `max_turns`. A backstop, not a target.
  There is deliberately **no money cap**: the default lane is a subscription lane that reports $0, so a
  dollar bound would never fire on the path most people use, while time and attempts always bind. Each
  attempt is a normal delegation and shows up in the Tab.
- **Write the check as the session's definition of done**, not a generic one. "The auth tests pass" is a
  goal; "tests probably pass" is not checkable, and a vague check makes a finished job look failed.

## `loop escalate` (built in)

Same contract as `loop verify` (external check is the goal, same stall guard, same states and exit
codes), but it climbs a price ladder: attempts run on the cheapest rung until the check fails there
`--per-tier` times (default 2, `OSRC_ESCALATE_PER_TIER`) or repeats the identical failure, and only then
does the next rung get delegated, carrying the last failure across as feedback.

```
outsourcerer loop escalate [-m <cheap>] [--ladder "m1,m2,m3"] --check "npm test" [--max N] [--max-minutes M] [--per-tier R] "make the auth tests pass"
```

- Default ladder: `haiku,glm-5.2,fable`, or `-m <model>` followed by `glm-5.2,fable` (override with
  `OSRC_ESCALATE_LADDER`). Rungs on the exclude list are dropped from the default ladder, out loud.
- The ladder needs 2 to 4 rungs, cheapest first. Every rung is validated before anything runs, so a typo
  at the top can never bill the bottom. A rung that steps down in tier gets a warning but still runs.
- Receipts: every attempt appends a row to `receipts.tsv` in the loop folder (attempt, rung, model, tier,
  lane, pass/fail/blocked, seconds), so "the cheap tier passed and the expensive one never ran" is a
  visible fact.
- Escalate loops cannot be resumed; start a fresh one (the cheap rung makes that inexpensive).

## `loop resume` (built in)

```
outsourcerer loop resume <loop-id> [--max N]
```

Picks up a `verify` loop that ended `blocked`, `max_turns`, or `max_time`, using its saved task, check,
model, verb, time bound, worktree, and accumulated failure feedback. Use only the loop id and optional
`--max N` (which must raise the attempt ceiling). A loop that already succeeded is refused, and so is
any replacement task text: start a new loop for a different task.

## Recipes you drive (no engine, just compose the verbs)

### sweep (until-dry): bulk find/fix with an unknown amount of work

Keep delegating rounds until **K consecutive rounds add nothing new** (default K=2) or a round cap.
Dedup findings against a file on disk, not in context.

```
seen=findings.md; dry=0
while [ "$dry" -lt 2 ]; do
  new=$(outsourcerer run -m glm "find the next batch of <X>; skip anything already in $seen")
  [ -z "$new_unique" ] && dry=$((dry+1)) || { append to $seen; dry=0; }
done
```

### best-of-N / tournament: no cheap way to verify, but you can compare

Generate N candidates in parallel on the cheap engine (disposable), then you rank and pick. Inherently
bounded, so it is the safest shape. The factory's `best-of-n` flow does the same with worktrees and a
held pick (`references/factory.md`).

```
outsourcerer fanout --max 4 -m glm -- "impl approach A" "impl approach B" "impl approach C"
# then: read each result, judge, keep the best.
```

### evaluator-optimizer: quality matters, "correct" isn't binary (copy, design, refactor)

generate → an advisor scores against an explicit rubric → refine. Stop when the score clears the bar or
a round yields no improvement (diminishing returns).

```
draft=$(outsourcerer run -m glm "write <thing>")
loop: score=$(outsourcerer second-opinion "score this 1-10 against: <rubric>. <draft>")
      [ score >= bar ] && stop; draft=$(outsourcerer run -m glm "improve per: <critique>")
```

### council-build: debate → decide → build → verify → test → launch

Model-typed roles: advisors = frontier (sol/fable/opus), builder = capable-cheap (glm/hy3), tester = you
(the orchestrator). Any stage can block and route back. The factory's `council-build` flow runs this
shape as a plan (`references/factory.md`); the manual version:

1. **debate**: two frontier advisors argue via interactive `session`, each critiquing the other's last
   turn, M rounds, until the plan converges:
   ```
   outsourcerer session start -m sol      # advisor A
   outsourcerer session start -m fable    # advisor B
   # loop M rounds: session read A -> session send B "rebut A's plan: <A>" -> session read B -> session send A "..."
   ```
2. **decide**: you synthesize the winning plan (or the advisors converge) and write it to a plan file.
3. **build**: hand the plan to the cheap engine as a bounded verify loop:
   `outsourcerer loop verify -m glm --worktree --check "<the tests>" "build per plan.md"`.
4. **verify**: an advisor checks fidelity: `outsourcerer run -m sol "does this diff match plan.md? list gaps"`.
5. **test**: you run the real suite and exercise it. The builder never judges its own work.
6. **launch gate**: ship only when verify and test pass; a failure routes back to build (or to debate if
   the plan itself was wrong).

## Safety checklist (every loop, built-in or recipe)

- A hard bound, always: `--max` and `--max-minutes` on the built-ins; the round or candidate count on
  the recipes. Spend is bounded by attempts × per-attempt cost and is visible in the Tab; there is no
  separate dollar ceiling, so the attempt and time bounds are your budget control.
- Stall detection: N no-change rounds → stop and surface.
- External verification, never self-report.
- A distinct `blocked` state that surfaces to a human.
- Worktree isolation for build and sweep work on a repo someone is using.
- Never unattended-infinite: scheduled runs wrap a bounded shape, they don't remove the caps.
