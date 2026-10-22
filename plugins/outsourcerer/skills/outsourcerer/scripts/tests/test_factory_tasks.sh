#!/usr/bin/env bash
# test_factory_tasks.sh -- factory track B: the plan/task store, readiness, claim atomicity, the
# context-handoff brief, hold/release, cancel/retry, done fallback, corrupt-file handling, and the
# CLI through a PATH symlink. No real delegate ever runs: _task_bg_launch is overridden after
# sourcing (the single seam into cmd_bg), except one end-to-end launch through the REAL bg path with
# a fake droid binary to prove the predicted worktree path/branch/base match what bg records.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-factory-tasks.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
export OSRC_FLEET_SUPERVISION=0 OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A small git repo for ship tasks.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
echo hi > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -q -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# Library harness: source the real script (factory files load from its folder), stub the launcher.
LIB="$TMP/lib.sh"
cat > "$LIB" <<EOF
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
LAUNCH_LOG="$TMP/launches"
_task_bg_launch() {
  local wd="\$1"; shift
  sleep "\${STUB_SLEEP:-0}"
  local id="20261022-120000-\$(printf '%06d' \$RANDOM)\${RANDOM}"
  mkdir -p "\$OSRC_JOBS/\$id"; echo running > "\$OSRC_JOBS/\$id/status"
  printf '%s|%s|%s|%s|%s\n' "\$id" "\$wd" "\${OSRC_WORKTREE:-}" "\${OSRC_WORKTREE_BASE:-}" "\${OSRC_TASK_REF:-}" >> "\$LAUNCH_LOG"
  printf '%s\n' "\$@" > "\$OSRC_JOBS/\$id/argv"
  [ "\${STUB_FAIL:-0}" = 1 ] && { echo "ERROR: stub refused" >&2; return 1; }
  echo "\$id"
}
EOF
L() { bash -c ". \"$LIB\"; $1"; }
O() { bash "$SRC" "$@"; }

# ---- loading
check "sourcing outsourcerer.sh loads the factory library" "L 'type _task_dispatch >/dev/null && type cmd_plan >/dev/null'"
mkdir -p "$TMP/bin"; ln -s "$SRC" "$TMP/bin/outsourcerer"
out="$(cd "$TMP" && PATH="$TMP/bin:$PATH" outsourcerer plan ls 2>&1)"
check "CLI through a PATH symlink finds factory-tasks.sh" "printf '%s' \"\$out\" | grep -q 'No plans yet'"

# ---- plan new / current / use
out="$(cd "$REPO" && O plan new alpha --goal 'ship the thing' 2>&1)"
pj="$OSRC_HOME/plans/alpha/plan.json"
check "plan new writes plan.json with schema, goal, repo, base_branch" \
  "[ \"\$(jq -r '[.schema,.name,.goal,.repo,.base_branch]|join(\"|\")' \"$pj\")\" = \"1|alpha|ship the thing|$REPO|main\" ]"
check "plan new makes the plan current" "[ \"\$(cat \"$OSRC_HOME/plans/current\")\" = alpha ]"
out="$(cd "$REPO" && O plan new alpha 2>&1)"; rc=$?
check "plan new refuses a duplicate name" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'already exists'"
out="$(cd "$TMP" && O plan new beta --no-repo --no-use 2>&1)"
check "--no-use keeps the current plan" "[ \"\$(cat \"$OSRC_HOME/plans/current\")\" = alpha ] && [ \"\$(jq -r .repo \"$OSRC_HOME/plans/beta/plan.json\")\" = '' ]"
O plan use beta >/dev/null 2>&1
check "plan use switches the current plan" "[ \"\$(cat \"$OSRC_HOME/plans/current\")\" = beta ]"
O plan use alpha >/dev/null 2>&1
out="$(O plan use nope 2>&1)"; rc=$?
check "plan use of a missing plan fails plainly" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'no plan named'"
out="$(O plan new 'bad name' 2>&1)"; rc=$?
check "invalid plan names are refused" "[ $rc -ne 0 ]"

# ---- ids + deps + readiness
SPEC="$TMP/spec.md"; printf 'SPEC-LINE-ONE\nThe widget must be blue.\n' > "$SPEC"
t1="$(O task add 'scout auth' --prompt 'map the auth flow' 2>/dev/null)"
t2="$(O task add 'build login' --shape ship --deps t1 --spec "$SPEC" --check 'make test' -m glm 2>/dev/null)"
t3="$(O task add 'write docs' --deps t1,t2 2>/dev/null)"
t4="$(O task add 'independent' 2>/dev/null)"
check "task ids are allocated t1..t4 in order" "[ \"$t1 $t2 $t3 $t4\" = 't1 t2 t3 t4' ]"
check "task JSON carries the contract fields and defaults" \
  "[ \"\$(jq -r '[.schema,.state,.shape,.verb,.deliver,.retries,.attempts,(.deps|join(\",\")),.model,.check]|join(\"|\")' \"$OSRC_HOME/plans/alpha/tasks/t2.json\")\" = '1|todo|ship|edit|local|1|0|t1|glm|make test' ]"
check "a scout task defaults to verb run and prompt = title when none given" \
  "[ \"\$(jq -r '.verb + \"|\" + .prompt' \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = 'run|independent' ]"
check "spec is stored as an absolute path" "[ \"\$(jq -r .spec \"$OSRC_HOME/plans/alpha/tasks/t2.json\")\" = \"$SPEC\" ]"
out="$(O task add 'orphan' --deps t9 2>&1)"; rc=$?
check "a dependency on a task that does not exist is refused" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 't9 does not exist'"
check "ready = todo with every dep done (t1, t4)" "[ \"\$(L '_task_ready alpha' | tr '\n' ' ')\" = 't1 t4 ' ]"
check "derived state marks t2/t3 blocked" \
  "[ \"\$(L '_task_view alpha' | jq -r 'map(select(.derived==\"blocked\"))|map(.id)|join(\",\")')\" = 't2,t3' ]"

# ---- _task_update + events
L "_task_update alpha t1 '.state = \"done\" | .result = \"auth uses JWT in cookies\"'"
check "_task_update applies the filter and bumps updated" \
  "[ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/t1.json\")\" = done ] && [ -n \"\$(jq -r .updated \"$OSRC_HOME/plans/alpha/tasks/t1.json\")\" ]"
check "a state change is logged to events.jsonl" \
  "jq -e 'select(.task==\"t1\" and .event==\"state\" and .from==\"todo\" and .to==\"done\")' \"$OSRC_HOME/plans/alpha/events.jsonl\" >/dev/null"
before="$(cat "$OSRC_HOME/plans/alpha/tasks/t4.json")"
L "_task_update alpha t4 'error(\"nope\")'" 2>/dev/null; rc=$?
check "an erroring filter changes nothing and returns 1" "[ $rc -ne 0 ] && [ \"\$(cat \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = \"\$before\" ]"
check "after t1 is done, t2 becomes ready (dependency order: t4 depth 0 first)" \
  "[ \"\$(L '_task_ready alpha' | tr '\n' ' ')\" = 't4 t2 ' ]"

# ---- dispatch (stubbed launcher)
jid="$(L '_task_dispatch alpha t2' 2>/dev/null)"; rc=$?
t2j="$OSRC_HOME/plans/alpha/tasks/t2.json"
check "dispatch prints the job id and records it" "[ $rc -eq 0 ] && [ -n \"$jid\" ] && [ \"\$(jq -r .job \"$t2j\")\" = \"$jid\" ] && [ \"\$(jq -r '.jobs|length' \"$t2j\")\" = 1 ]"
check "dispatch moves the task to running and counts the attempt" "[ \"\$(jq -r '.state + \"|\" + (.attempts|tostring)' \"$t2j\")\" = 'running|1' ]"
check "ship dispatch records worktree, branch, base_sha" \
  "[ \"\$(jq -r '[.worktree,.branch,.base_sha]|join(\"|\")' \"$t2j\")\" = \"$REPO/.outsourcerer/worktrees/$jid|outsourcerer/$jid|$HEAD_SHA\" ]"
line="$(grep "^$jid|" "$TMP/launches")"
check "ship launch runs in the plan repo with OSRC_WORKTREE=1 pinned to the base commit and a task ref" \
  "[ \"\$line\" = \"$jid|$REPO|1|$HEAD_SHA|alpha/t2\" ]"
check "the launch passes the task's verb and model, and the brief as the prompt" \
  "[ \"\$(sed -n 1,3p \"$OSRC_HOME/jobs/$jid/argv\" | tr '\n' '|')\" = 'edit|-m|glm|' ] && grep -q '^# Task alpha/t2: build login' \"$OSRC_HOME/jobs/$jid/argv\""
check "the job dir gets a task_ref back-link" "[ \"\$(cat \"$OSRC_HOME/jobs/$jid/task_ref\")\" = alpha/t2 ]"
out="$(L '_task_dispatch alpha t2' 2>&1)"; rc=$?
check "dispatching a running task is refused" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'already underway'"
out="$(L '_task_dispatch alpha t3' 2>&1)"; rc=$?
check "dispatching a blocked task is refused and names the blocker" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'waits on t2 (running)'"
jid4="$(L '_task_dispatch alpha t4' 2>/dev/null)"
check "scout dispatch does not ask for a worktree" "grep -q \"^$jid4|$REPO|0||alpha/t4\$\" \"$TMP/launches\""

# ---- claim atomicity: two concurrent dispatches of one task, exactly one wins
t5="$(O task add 'race me' 2>/dev/null)"
: > "$TMP/race"
for i in 1 2 3; do ( STUB_SLEEP=0.2 L "_task_dispatch alpha $t5" >> "$TMP/race" 2>/dev/null ) & done
wait
check "concurrent dispatch: exactly one launch wins" \
  "[ \"\$(grep -c . \"$TMP/race\")\" = 1 ] && [ \"\$(grep -c 'alpha/$t5\$' \"$TMP/launches\")\" = 1 ] && [ \"\$(jq -r .attempts \"$OSRC_HOME/plans/alpha/tasks/$t5.json\")\" = 1 ]"
: > "$TMP/adds"
for i in 1 2 3 4 5; do ( O task add "par $i" >> "$TMP/adds" 2>/dev/null ) & done
wait
check "concurrent task add allocates five distinct ids" "[ \"\$(sort -u \"$TMP/adds\" | grep -c '^t[0-9]')\" = 5 ]"

# ---- launch failure is surfaced, not silent
t6="$(O task add 'will not launch' 2>/dev/null)"
out="$(STUB_FAIL=1 L "_task_dispatch alpha $t6" 2>&1)"; rc=$?
check "a failed launch fails the task with a reason" \
  "[ $rc -ne 0 ] && [ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = failed ] && jq -r .result \"$OSRC_HOME/plans/alpha/tasks/$t6.json\" | grep -q 'did not launch'"
check "a failed task raises a wake event for the heartbeat" \
  "grep -q '\"kind\":\"factory-task\".*\"task\":\"$t6\".*\"task_state\":\"failed\"' \"$OSRC_HOME/wake-queue.jsonl\""

# ---- the brief (context handoff)
# Make t2 a finished ship task with a report and t1's output in its job.
mkdir -p "$OSRC_HOME/jobs/J1"; echo done > "$OSRC_HOME/jobs/J1/status"
printf 'FULL-SCOUT-OUTPUT: login posts to /api/session\n' > "$OSRC_HOME/jobs/J1/last.txt"
L "_task_update alpha t1 '.job = \"J1\" | .hold.answer = \"use cookies, not localStorage\"'"
L "_task_update alpha t2 '.state = \"done\" | .result = \"login form built\" | .head_sha = \"abc123\"'"
mkdir -p "$OSRC_HOME/plans/alpha/tasks/t2"; printf 'REPORT-T2: added LoginForm.tsx\n' > "$OSRC_HOME/plans/alpha/tasks/t2/report.md"
L "_task_update alpha t3 '.state = \"held\" | .hold = {reason:\"tone: formal or casual?\",until:\"\",answer:\"\"}'"
O task release t3 --answer 'casual, short sentences' >/dev/null 2>&1
bp="$(L '_task_brief alpha t3')"
B="$(cat "$bp" 2>/dev/null)"
has() { printf '%s' "$B" | grep -qF -- "$1"; }
check "brief path is tasks/<tid>/brief.md" "[ \"$bp\" = \"$OSRC_HOME/plans/alpha/tasks/t3/brief.md\" ]"
check "brief opens with the plan goal" "has 'Plan goal: ship the thing'"
check "brief carries the task prompt" "has '## Your task' && has 'write docs'"
check "brief names each dependency with title and state" "has '### t1: scout auth (scout, done)' && has '### t2: build login (ship, done)'"
check "brief carries dep result summaries" "has 'Summary: auth uses JWT in cookies' && has 'Summary: login form built'"
check "brief carries dep output from the job's last.txt" "has 'FULL-SCOUT-OUTPUT: login posts to /api/session'"
check "brief prefers a dep's report.md and links the full report" "has 'REPORT-T2: added LoginForm.tsx' && has \"Full report: $OSRC_HOME/plans/alpha/tasks/t2/report.md\""
check "brief gives ship deps' branch and head commit" "has 'branch \`outsourcerer/' && has 'at commit abc123'"
check "brief carries a dependency's captain answer" "has 'Captain decided on t1: use cookies, not localStorage'"
check "brief carries this task's own captain decision" "has '## Decision from the captain' && has 'Question: tone: formal or casual?' && has 'casual, short sentences'"
check "a scout brief says change nothing" "has 'Do not change any files'"
b2="$(cat "$(L '_task_brief alpha t2')")"
check "a ship brief carries the spec contents and the check" \
  "printf '%s' \"\$b2\" | grep -q 'SPEC-LINE-ONE' && printf '%s' \"\$b2\" | grep -qF '\`make test\`' && printf '%s' \"\$b2\" | grep -q 'Commit your finished work'"
# bounded: a huge dep output is trimmed; a huge spec is linked not pasted
head -c 20000 /dev/zero | tr '\0' 'x' > "$OSRC_HOME/jobs/J1/last.txt"
BIG="$TMP/big.md"; head -c 70000 /dev/zero | tr '\0' 'y' > "$BIG"
t7="$(O task add 'big' --deps t1 --spec "$BIG" 2>/dev/null)"
b7="$(cat "$(L "_task_brief alpha $t7")")"
check "brief caps each dependency's output (~4KB) with a visible trim marker" \
  "[ \"\$(printf '%s' \"\$b7\" | wc -c | tr -d ' ')\" -lt 8000 ] && printf '%s' \"\$b7\" | grep -q 'trimmed'"
check "a spec over 64KB is linked by path, not pasted" "printf '%s' \"\$b7\" | grep -q \"Read it in full before you start: $BIG\""

# ---- hold / release
out="$(O task hold t4 --reason 'is this still needed?' 2>&1)"; rc=$?
check "hold refuses a running task" "[ $rc -ne 0 ]"
O task hold "$t7" --reason 'pick A or B' --until 'Friday' >/dev/null 2>&1
check "hold sets state held with reason and until" \
  "[ \"\$(jq -r '.state + \"|\" + .hold.reason + \"|\" + .hold.until' \"$OSRC_HOME/plans/alpha/tasks/$t7.json\")\" = 'held|pick A or B|Friday' ]"
check "hold raises a wake event" "grep -q '\"task\":\"$t7\".*\"task_state\":\"held\"' \"$OSRC_HOME/wake-queue.jsonl\""
out="$(L "_task_dispatch alpha $t7" 2>&1)"; rc=$?
check "a held task cannot be dispatched" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'held for a decision'"
show="$(O plan show 2>&1)"
check "plan show puts held and failed tasks in Captain's Call" \
  "printf '%s' \"\$show\" | sed -n \"/^Captain's Call/,/^Done/p\" | grep -q \"$t7 \\[held\\] big - needs a decision: pick A or B\" && printf '%s' \"\$show\" | sed -n \"/^Captain's Call/,/^Done/p\" | grep -q \"$t6 \\[failed\\]\""
out="$(O task release "$t7" 2>&1)"; rc=$?
check "release without an answer is refused" "[ $rc -ne 0 ]"
O task release "$t7" --answer 'B' >/dev/null 2>&1
check "release returns the task to todo with the answer kept" \
  "[ \"\$(jq -r '.state + \"|\" + .hold.answer' \"$OSRC_HOME/plans/alpha/tasks/$t7.json\")\" = 'todo|B' ]"
out="$(O task release "$t7" --answer 'again' 2>&1)"; rc=$?
check "release of a task that is not held is refused" "[ $rc -ne 0 ]"
t8="$(O task add 'pick winner' --hold 'which candidate?' 2>/dev/null)"
O task release "$t8" --answer 'candidate 2' --done >/dev/null 2>&1
check "release --done closes a decision task with the answer as its result" \
  "[ \"\$(jq -r '.state + \"|\" + .result' \"$OSRC_HOME/plans/alpha/tasks/$t8.json\")\" = 'done|candidate 2' ]"

# ---- failed dep blocks dependents; cancel/retry
t9="$(O task add 'after failed' --deps "$t6" 2>/dev/null)"
check "a failed dependency keeps dependents blocked" \
  "[ \"\$(L '_task_view alpha' | jq -r --arg id $t9 '.[]|select(.id==\$id)|.derived + \"|\" + (.blocked_by|map(.id+\":\"+.state)|join(\",\"))')\" = \"blocked|$t6:failed\" ]"
show="$(O plan show 2>&1)"
check "plan show names the failed blocker as needing the captain" "printf '%s' \"\$show\" | grep -q \"$t9 \\[blocked\\] after failed - waiting on $t6 (failed), needs the captain\""
check "plan show lists dependencies" "printf '%s' \"\$show\" | grep -q '^  t3 <- t1, t2\$'"
O task retry "$t6" >/dev/null 2>&1
check "retry puts a failed task back to todo and clears its job" \
  "[ \"\$(jq -r '.state + \"|\" + .job' \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = 'todo|' ]"
out="$(O task retry "$t6" 2>&1)"; rc=$?
check "retry of a todo task is refused" "[ $rc -ne 0 ]"
O task cancel "$t6" >/dev/null 2>&1
check "cancel marks the task canceled" "[ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = canceled ]"
check "a canceled dependency keeps dependents blocked" \
  "[ \"\$(L '_task_view alpha' | jq -r --arg id $t9 '.[]|select(.id==\$id)|.derived')\" = blocked ]"
O task retry "$t6" >/dev/null 2>&1
check "retry also revives a canceled task" "[ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = todo ]"
b6="$(cat "$(L "_task_brief alpha $t6")")"
check "a retried task's brief tells the worker what went wrong before" "printf '%s' \"\$b6\" | grep -q '## Earlier attempt'"

# ---- task done: fallback contract, then track C's hook when present
L "_task_update alpha t4 '.job = \"J4\"'"; mkdir -p "$OSRC_HOME/jobs/J4"; echo running > "$OSRC_HOME/jobs/J4/status"
out="$(O task done t4 2>&1)"; rc=$?
check "done refuses while the job is still running and restores the state" \
  "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'still running' && [ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = running ]"
echo done > "$OSRC_HOME/jobs/J4/status"; printf 'Independent finding: all good\n' > "$OSRC_HOME/jobs/J4/last.txt"
out="$(O task done t4 2>&1)"; rc=$?
check "done passes on a finished job with a result (fallback contract)" "[ $rc -eq 0 ] && [ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = done ]"
check "done copies a scout's output to report.md and fills the result" \
  "grep -q 'Independent finding' \"$OSRC_HOME/plans/alpha/tasks/t4/report.md\" && jq -r .result \"$OSRC_HOME/plans/alpha/tasks/t4.json\" | grep -q 'Independent finding'"
check "done passes through verifying (logged)" \
  "jq -e 'select(.task==\"t4\" and .to==\"verifying\")' \"$OSRC_HOME/plans/alpha/events.jsonl\" >/dev/null"
L "_task_update alpha $t5 '.job = \"J5\"'"; mkdir -p "$OSRC_HOME/jobs/J5"; echo done > "$OSRC_HOME/jobs/J5/status"; echo x > "$OSRC_HOME/jobs/J5/last.txt"
out="$(bash -c ". \"$LIB\"; _factory_done_check() { echo 'contract says no: no commits'; return 1; }; cmd_task done $t5" 2>&1)"; rc=$?
check "done uses _factory_done_check when track C defines it" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'contract says no'"
out="$(bash -c ". \"$LIB\"; _factory_done_check() { _task_update \"\$1\" \"\$2\" '.evidence = \$e | .head_sha = \$h' --arg e /x/evidence.json --arg h feed; echo 'contract ok'; return 0; }; cmd_task done $t5" 2>&1)"; rc=$?
check "a done check that writes the task itself (track C style) does not deadlock and is honored" \
  "[ $rc -eq 0 ] && [ \"\$(jq -r '.state + \"|\" + .evidence + \"|\" + .head_sha' \"$OSRC_HOME/plans/alpha/tasks/$t5.json\")\" = 'done|/x/evidence.json|feed' ]"
L "_task_update alpha $t5 '.state = \"running\" | .landed = true | .landed_into = \"main\" | .landed_sha = \"0123456789abcdef\" | .pr = \"https://example.invalid/pr/1\"'"
out="$(O task show "$t5" 2>&1)"
check "task show displays landed status and PR when track C set them" \
  "printf '%s' \"\$out\" | grep -q 'landed:   yes into main at 0123456789ab' && printf '%s' \"\$out\" | grep -q 'pr:       https://example.invalid/pr/1'"
O task done "$t5" --force --result 'did it by hand' >/dev/null 2>&1
check "done --force marks done by hand with a result" "[ \"\$(jq -r '.state + \"|\" + .result' \"$OSRC_HOME/plans/alpha/tasks/$t5.json\")\" = 'done|did it by hand' ]"
out="$(O task fail t4 --reason x 2>&1)"; rc=$?
check "fail of a done task is refused" "[ $rc -ne 0 ]"

# ---- ls / show / ready CLI
out="$(O task ls 2>&1)"
check "task ls prints a table with derived states" "printf '%s' \"\$out\" | grep -q '^ID' && printf '%s' \"\$out\" | grep -q 'scout auth'"
out="$(O task show t2 2>&1)"
check "task show prints the task with its files and events" "printf '%s' \"\$out\" | grep -q 'alpha/t2: build login' && printf '%s' \"\$out\" | grep -q 'recent events'"
check "task show --json is the raw task" "O task show t2 --json | jq -e '.id == \"t2\"' >/dev/null"
out="$(O task ready 2>&1)"
check "task ready lists ready tids with titles" "printf '%s' \"\$out\" | grep -q \"^$t6\""
out="$(O plan ls 2>&1)"
check "plan ls marks the current plan" "printf '%s' \"\$out\" | grep -q '^\\* alpha'"

# ---- corrupt files are survived, not fatal
echo '{not json' > "$OSRC_HOME/plans/alpha/tasks/$t9.json"
out="$(O task ls 2>&1)"
check "a damaged task file is skipped with a warning; the rest still list" \
  "printf '%s' \"\$out\" | grep -q 'skipping damaged task file' && printf '%s' \"\$out\" | grep -q 'scout auth'"
out="$(L "_task_get alpha $t9" 2>&1)"; rc=$?
check "_task_get on a damaged file returns 1 with a plain reason" "[ $rc -eq 1 ] && printf '%s' \"\$out\" | grep -q 'damaged'"
L "_task_update alpha $t9 '.state = \"todo\"'" >/dev/null 2>&1; rc=$?
check "_task_update on a damaged file refuses" "[ $rc -ne 0 ] && grep -q 'not json' \"$OSRC_HOME/plans/alpha/tasks/$t9.json\""
check "_task_get of a missing task returns 1" "! L '_task_get alpha t999' 2>/dev/null"
cp "$OSRC_HOME/plans/alpha/plan.json" "$TMP/plan.bak"; echo 'garbage' > "$OSRC_HOME/plans/alpha/plan.json"
out="$(O plan show alpha 2>&1)"; rc=$?
check "plan show survives a damaged plan.json" "[ $rc -eq 0 ] && printf '%s' \"\$out\" | grep -q 'damaged'"
cp "$TMP/plan.bak" "$OSRC_HOME/plans/alpha/plan.json"

# ---- lock: a dead holder's lock is reclaimed
mkdir -p "$OSRC_HOME/plans/alpha/.lock"; echo '999999 Thu Jan  1 00:00:00 1970' > "$OSRC_HOME/plans/alpha/.lock/owner"
L "_task_update alpha t1 '.result = \"after stale lock\"'" 2>/dev/null; rc=$?
check "a stale lock from a dead process is reclaimed" "[ $rc -eq 0 ] && [ \"\$(jq -r .result \"$OSRC_HOME/plans/alpha/tasks/t1.json\")\" = 'after stale lock' ] && [ ! -d \"$OSRC_HOME/plans/alpha/.lock\" ]"

# ---- plan rm / plan run delegation
tr_="$(O task add 'keep running' 2>/dev/null)"; L "_task_dispatch alpha $tr_" >/dev/null 2>&1
out="$(O plan rm alpha 2>&1)"; rc=$?
check "plan rm refuses while work is underway" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'still has work underway'"
O plan rm beta >/dev/null 2>&1
check "plan rm removes an idle plan" "[ ! -d \"$OSRC_HOME/plans/beta\" ]"
if L 'type cmd_plan_run >/dev/null 2>&1'; then
  ok "plan run is provided by factory-flow.sh (delegation not exercised)"
else
  out="$(O plan run 2>&1)"; rc=$?
  check "plan run without factory-flow.sh says what is missing" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'factory-flow.sh'"
fi
check "ship task in a plan without a repo fails closed" \
  "O plan new norepo --no-repo >/dev/null 2>&1 && O task add 'build' --shape ship >/dev/null 2>&1 && ! L '_task_dispatch norepo t1' 2>/dev/null && jq -r .result \"$OSRC_HOME/plans/norepo/tasks/t1.json\" | grep -q 'no repo'"

# ---- end to end through the REAL bg path (fake droid binary, no model call)
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/droid"; chmod +x "$FAKEBIN/droid"
(cd "$REPO" && O plan new e2e --goal 'real launch' >/dev/null 2>&1)
O task add 'real ship' --shape ship --provider droid --plan e2e >/dev/null 2>&1
jid="$(cd "$TMP" && PATH="$FAKEBIN:$PATH" OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 O task start t1 --plan e2e 2>/dev/null | head -1)"
i=0; while [ "$i" -lt 100 ]; do [ -f "$OSRC_HOME/jobs/$jid/meta.json" ] && break; i=$((i+1)); sleep 0.1; done
ej="$OSRC_HOME/plans/e2e/tasks/t1.json"
if [ -n "$jid" ] && [ -f "$OSRC_HOME/jobs/$jid/meta.json" ]; then
  check "real bg launch: the job's worktree/branch/base match what the task recorded" \
    "[ \"\$(jq -r '[.worktree,.branch,.base_sha]|join(\"|\")' \"$OSRC_HOME/jobs/$jid/meta.json\")\" = \"\$(jq -r '[.worktree,.branch,.base_sha]|join(\"|\")' \"$ej\")\" ]"
  check "real bg launch: the task is running on that job" "[ \"\$(jq -r '.state + \"|\" + .job' \"$ej\")\" = \"running|$jid\" ]"
else
  bad "real bg launch produced no job (jid='$jid'): $(cat "$OSRC_HOME/plans/e2e/tasks/t1/launch.log" 2>/dev/null | tail -3)"
fi
i=0; while [ "$i" -lt 100 ]; do case "$(cat "$OSRC_HOME/jobs/$jid/status" 2>/dev/null)" in running|launching) sleep 0.1; i=$((i+1)) ;; *) break ;; esac; done
# Let the detached job finish its bookkeeping (ledger/outcome rows) before the temp dir goes.
i=0; while [ "$i" -lt 150 ] && pgrep -f "$TMP" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
git -C "$REPO" worktree remove --force "$REPO/.outsourcerer/worktrees/$jid" >/dev/null 2>&1 || true

# ---- a ship worker that cannot get its own worktree must never fall back to the caller's checkout
# Outside every repo (TMP lives inside this checkout), and git told not to look above it.
NOGIT="$(mktemp -d)"; NOGIT="$(cd "$NOGIT" && pwd -P)"
( cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$(dirname "$NOGIT")" OSRC_WORKTREE=1 OSRC_WORKTREE_REQUIRED=1 bash -c ". \"$LIB\"; run_job wtreq droid edit 'touch SHOULD_NOT_EXIST'" ) >/dev/null 2>&1
check "required worktree unavailable: the job fails closed" "[ \"\$(cat \"$OSRC_HOME/jobs/wtreq/status\" 2>/dev/null)\" = failed ] && grep -q worktree-required-unavailable \"$OSRC_HOME/jobs/wtreq/reason\""
check "required worktree unavailable: nothing ran in the caller's folder" "[ ! -e \"$NOGIT/SHOULD_NOT_EXIST\" ]"
rm -rf "$NOGIT"

echo
echo "factory tasks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
