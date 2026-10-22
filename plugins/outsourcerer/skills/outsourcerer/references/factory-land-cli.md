# `land` and the done contract (factory, 0.14)

Flag-level reference for `land` and the done contract it enforces. Source: `scripts/factory-land.sh`.
Tests: `scripts/tests/test_factory_land.sh`. The user-facing guide is `references/factory.md`.

## CLI

```
outsourcerer land <task-id|job-id> [--plan P] [--check CMD | --no-check] [--setup CMD]
                  [--into BRANCH] [--pr] [--dry-run] [--force]
```

| Flag | Meaning | Default |
|---|---|---|
| `<task-id>` | a plan task, `t<N>` | required (or a job id) |
| `<job-id>` | an ad-hoc `bg`/`fanout --worktree` job (no task) | |
| `--plan P` | plan the task belongs to | the current plan (`plan use`) |
| `--check CMD` | shell check run in the worker worktree and again on the merged result | the task's `check`; a bare job has none, so it needs `--check` or `--no-check` |
| `--no-check` | land with no check at all (explicit opt-out; required for an unchecked bare job) | off |
| `--setup CMD` | run CMD in the scratch checkout of the merged result before the check (e.g. `npm ci`); bounded by `OSRC_LAND_SETUP_TIMEOUT` (default 900s); recorded as `land.setup` | none |
| `--into BRANCH` | branch to land on | plan `base_branch`, else the repo's checked-out branch |
| `--pr` | push the branch to `origin` and `gh pr create`, instead of moving BRANCH | off (never implicit) |
| `--dry-run` | run every step (done check, merge, setup, re-check) in scratch; move nothing and write nothing to the task or its evidence. Outputs go to `$OSRC_HOME/land/dry-run/<plan>_<tid>/` | off |
| `--force` | land a task marked `failed` (after the full gate). Never lands a held or canceled task | off |

`--pr` and `--dry-run` together are refused, as are `--check` and `--no-check`. Exit 0 = landed / PR opened / dry run green / already landed. Exit 1 = refused, with one plain line saying why and what to do next.

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
7. no live secret ADDED in `git diff base..HEAD`: only added (`+`) lines are scanned, and only for key VALUES (`sk-…`, Stripe `sk_live_`/`rk_live_`, `ghp_`, `github_pat_`, Slack `xox?-`/`xapp-`, AWS `AKIA…`, Google `AIza…`, PEM private keys). Code that only names a variable such as `OPENROUTER_API_KEY`, or a commit that deletes a leaked key, passes. Same patterns as crew's staged scan (`OSRC_SECRET_ADDED_ERE`), `--text --no-ext-diff --no-textconv`, diff captured before matching; an unreadable diff fails closed
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

0. **Task state.** Land starts only from `running`, `verifying` or `done` (`failed` only with `--force`). `todo`, `held` and `canceled` are refused with the next step to take. The state is checked again after waiting in the queue and once more right before the target moves, so a cancel or hold that arrives mid-land wins (nothing moves). Scout tasks are refused; a task already `landed` is a no-op (exit 0).
1. **Done contract** (outside the queue). Refuses unless it passes. It is evaluated in-process: the exact head commit it verified is kept privately and is the one merged, so neither later edits in the worker worktree nor a concurrent rewrite of `evidence.json` can change what lands.
2. **Merge queue.** A per-repo lock (`$OSRC_HOME/locks/land-<cksum of repo path>`), one land at a time. A waiter prints once who holds it (`land p/t3 into main (since ...)`, pid). Bounded wait: `OSRC_LAND_LOCK_WAIT` seconds (default 900), then a clear "gave up" line. A lock whose owner process is provably dead is reclaimed; a live owner is never broken by age. The owner is the land's own (sub)shell pid, also on bash 3.2. Holding the lock, land removes scratch `land-*` worktrees left by a land that was killed (owner recorded in `$OSRC_HOME/land/active/`, dead or missing); a live owner's is kept.
3. If the target is in the middle of a rebase or bisect in any worktree of the repo (`rebase-merge`/`rebase-apply` `head-name`, `BISECT_START`): refuse. Checked again right before the target moves.
4. If the head is already in the target: accepted only when an earlier land put it there (this work's own land record, or a landed task of the plan whose landed commit contains it); the task is then marked landed. Otherwise refused: the commit reached the target without the merged-result check (for example a worker or a person merged it by hand).
5. If the target is checked out somewhere with uncommitted tracked changes, or the work adds files that already exist there as untracked or git-ignored files (a worker can `git add -f` an ignored `local.cfg`): refuse before doing any work, listing the paths.
6. **Fresh integration worktree** (detached, at the target tip) under `<repo>/.outsourcerer/worktrees/land-<id>`. `git merge --no-ff` of the verified head, message `land(<plan>/<tid>): <title>` (bare job: `land(<job-id>): <title or branch>`). Repo hooks off for the checkout and the merge (no post-checkout either), no gpg signing; the user's git identity is used, falling back to a noreply identity only when none is configured.
7. **Conflict**: merge aborted, target untouched. The task becomes `held` with `hold.reason = "merge conflict with <into>: <files>; rebase the task branch or retry"`, so a scheduler never loops on it; event `land_conflict` plus the held wake event. The error says both ways out: rebase in the worker worktree then `task release <tid> --done --answer "rebased"` and land again, or `task release <tid> --answer "..."` to let a worker redo it.
8. **`--setup`** (optional) runs in the integration worktree, then **the check is re-run on the merged result.** That checkout is CLEAN: it has none of the worker worktree's untracked files (`node_modules`, `.venv`, build output), so a check that needs them fails there; the failure message says so and points at `--setup`. A failing setup refuses (target and task untouched; output at `land-setup.out`). A red check (any non-zero, incl. timeout): target untouched, task `state=failed` (only from a state land may finish), `result="merge breaks check"` (a timeout says so), event `land_failed`, wake event, the last lines of the check printed. Output at `tasks/<tid>/land-check.out`.
9. `--dry-run`: stop here and report what would land. No ref moves, and nothing is written to the task or its `evidence.json` (not even the done check's evidence); the dry run's own record and outputs are in `$OSRC_HOME/land/dry-run/<label>/`.
10. `--pr`: push the verified head to `origin/<task branch>`, `gh pr create --base <target> --head <branch>`; the task gets `.pr=<url>`, event `pr_opened`. Target not moved, task not marked landed.
11. **Fast-forward the target**, never clobbering (after a last look at the task state, the target tip and any rebase/bisect):
    - target not checked out anywhere: `git update-ref` with the old tip as the expected value (atomic compare-and-swap);
    - target checked out (e.g. the main checkout): only if that tree has no uncommitted tracked changes, is at the old tip, and no path the merge adds exists there as an untracked or ignored file; then `merge --ff-only --no-overwrite-ignore` there (hooks off).
    - target moved during the land: refuse, nothing changed.
12. Mark the task `landed=true, landed_sha, landed_into, evidence`, and `state=done` when it is still in a state land may finish (a hold/cancel that slipped in after the last look is kept, with a note); event `landed`.

Always: the integration worktree is removed (trap, every exit path) and the lock released. The worker's worktree and branch are never touched; remove them with `outsourcerer cleanup <job-id>`.

**Bare job id**: the job must have a `worktree.json` (launched with `--worktree`). It has no check of its own, so land requires `--check CMD` or an explicit `--no-check`. Evidence goes to `$OSRC_JOBS/<job-id>/evidence.json`.

**Not a sandbox.** The check and setup run the repo's own code, and workers share the repo's refs. The gate catches mistakes (unverified merges, a target moved under it, a hand-merged head, clobbered local files), not a hostile worker that rewrites refs on purpose; review untrusted work before landing it.

## Task fields `land` adds (beyond the contract schema)
`landed` (bool), `landed_sha`, `landed_into`, `pr` (URL). Events: `land_started`, `land_conflict`, `land_failed`, `pr_opened`, `landed`. Land verdicts in `evidence.land.verdict`: `landed`, `pr_opened`, `dry_run_ok`, `conflict`, `check_failed`, `setup_failed`.

## Environment
`OSRC_LAND_LOCK_WAIT` (default 900s), `OSRC_CHECK_TIMEOUT` (default 300s), `OSRC_LAND_SETUP_TIMEOUT` (default 900s), `OSRC_STATE_LOCK_STALE_SECS` (ownerless-lock grace, default 30s).
