# `land` and the done contract (factory, 0.14)

Reference for the docs builder. Source: `scripts/factory-land.sh`. Tests: `scripts/tests/test_factory_land.sh`.

## CLI

```
outsourcerer land <task-id|job-id> [--plan P] [--check CMD] [--into BRANCH] [--pr] [--dry-run]
```

| Flag | Meaning | Default |
|---|---|---|
| `<task-id>` | a plan task, `t<N>` | required (or a job id) |
| `<job-id>` | an ad-hoc `bg`/`fanout --worktree` job (no task) | |
| `--plan P` | plan the task belongs to | the current plan (`plan use`) |
| `--check CMD` | shell check run in the worker worktree and again on the merged result | the task's `check`; for a bare job, none unless given |
| `--into BRANCH` | branch to land on | plan `base_branch`, else the repo's checked-out branch |
| `--pr` | push the branch to `origin` and `gh pr create`, instead of moving BRANCH | off (never implicit) |
| `--dry-run` | run every step (done check, merge, re-check) in scratch, move nothing, change no task state | off |

`--pr` and `--dry-run` together are refused. Exit 0 = landed / PR opened / dry run green / already landed. Exit 1 = refused, with one plain line saying why and what to do next.

## Done contract: `_factory_done_check <plan> <tid> [check-override]`

rc 0 = done, rc 1 = not done. Prints one line: `t3 done: ...` or `t3 not done: ...`. Always writes `plans/<plan>/tasks/<tid>/evidence.json` and sets the task's `.evidence` (plus `.head_sha` for ship). It calls `_task_update`, so callers must not hold the plan lock while calling it. Used by `task done`, the scheduler, and `land`.

**scout**: the job's `status` is `done` or `done?`, and `last.txt` (fallback `out.log`) has non-blank text. The text is copied to `tasks/<tid>/report.md`. No commits needed. The task `check` is not run for scouts.

**ship**, checked in this order (first failure is the reason):
1. a job is on record and its status is `done` / `done?`
2. the worktree exists (task `.worktree`, fallback the job's `worktree.json`)
3. a usable base commit (task `.base_sha`, fallback `worktree.json`)
4. at least one commit in `base..HEAD`
5. no uncommitted changes to tracked files (untracked files are ignored)
6. HEAD is on a named branch (`refs/heads/*` contains it), not only a detached HEAD
7. no live secret in `git diff base..HEAD` (same patterns as crew's staged scan, `--text --no-ext-diff --no-textconv`, diff captured before matching; an unreadable diff fails closed)
8. the check, if set, passes in the worktree (bounded by `OSRC_CHECK_TIMEOUT`, default 300s; 124 = timed out, 125 = could not start)

`evidence.json`:
```json
{"task":"t3","shape":"ship","job":"<id>","base_sha":"..","head_sha":"..",
 "check":{"cmd":"make test","rc":0,"signature":"<cksum of normalized output>","tail":"<last 20 lines>"},
 "secret_scan":"clean|blocked|not_run","verdict":"done|not_done","reason":"..","ts":"..",
 "land":{...}}
```
`check.rc` is `null` when no check ran. `secret_scan` is `not_run` when an earlier rule failed first. `land` is added by `land` (below). Check output is kept at `tasks/<tid>/check.out`.

## What `land` does

1. **Done contract** (outside the queue). Refuses unless it passes. The exact head commit it verified is the one merged, so later edits in the worker worktree can't slip in. Refuses scout tasks, canceled tasks; a task already `landed` is a no-op (exit 0).
2. **Merge queue.** A per-repo lock (`$OSRC_HOME/locks/land-<cksum of repo path>`), one land at a time. A waiter prints once who holds it (`land p/t3 into main (since ...)`, pid). Bounded wait: `OSRC_LAND_LOCK_WAIT` seconds (default 900), then a clear "gave up" line. A lock whose owner process is provably dead is reclaimed; a live owner is never broken by age.
3. If the head is already in the target: report it, mark the task landed, stop.
4. If the target is checked out somewhere with uncommitted tracked changes: refuse before doing any work.
5. **Fresh integration worktree** (detached, at the target tip) under `<repo>/.outsourcerer/worktrees/land-<id>`. `git merge --no-ff` of the verified head, message `land(<plan>/<tid>): <title>` (bare job: `land(<job-id>): <title or branch>`). Repo hooks off, no gpg signing; the user's git identity is used, falling back to a noreply identity only when none is configured.
6. **Conflict**: merge aborted, target untouched, task state unchanged, event `land_conflict`, wake event, conflicting files listed in the error.
7. **Re-run the check on the merged result.** Red (any non-zero, incl. timeout): target untouched, task `state=failed`, `result="merge breaks check"` (a timeout says so), event `land_failed`, wake event, the last lines of the check printed. Output at `tasks/<tid>/land-check.out`.
8. `--dry-run`: stop here and report what would land. No ref moves, no task state change (evidence still records `land.mode="dry-run"`).
9. `--pr`: push the verified head to `origin/<task branch>`, `gh pr create --base <target> --head <branch>`; the task gets `.pr=<url>`, event `pr_opened`. Target not moved, task not marked landed.
10. **Fast-forward the target**, never clobbering:
    - target not checked out anywhere: `git update-ref` with the old tip as the expected value (atomic compare-and-swap);
    - target checked out (e.g. the main checkout): only if that tree has no uncommitted tracked changes and is at the old tip, then `merge --ff-only` there (hooks off). An untracked file in the way makes it refuse, not overwrite.
    - target moved during the land: refuse, nothing changed.
11. Mark the task `landed=true, state=done, landed_sha, landed_into, evidence`; event `landed`.

Always: the integration worktree is removed (trap, every exit path) and the lock released. The worker's worktree and branch are never touched; remove them with `outsourcerer cleanup <job-id>`.

**Bare job id**: the job must have a `worktree.json` (launched with `--worktree`). The check comes only from `--check` (without it, land notes that the merged result is not re-verified). Evidence goes to `$OSRC_JOBS/<job-id>/evidence.json`.

## Task fields `land` adds (beyond the contract schema)
`landed` (bool), `landed_sha`, `landed_into`, `pr` (URL). Events: `land_started`, `land_conflict`, `land_failed`, `pr_opened`, `landed`.

## Environment
`OSRC_LAND_LOCK_WAIT` (default 900s), `OSRC_CHECK_TIMEOUT` (default 300s), `OSRC_STATE_LOCK_STALE_SECS` (ownerless-lock grace, default 30s).
