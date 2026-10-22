#!/usr/bin/env bash
# test_factory_land.sh -- done contract (_factory_done_check) + merge gate (`land`), Track C of 0.14.
# Real temp git repos, no network, no model calls. A fake `gh` stands in for --pr.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LAND="$HERE/../factory-land.sh"
[ -f "$SRC" ] && [ -f "$LAND" ] || { echo "FAIL: cannot find $SRC or $LAND"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

TMP="$(mktemp -d "$HERE/.test-factory-land.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Driver: source the main script as a library, then factory-land.sh, then (only if Track B's task
# store isn't present) a minimal TEST-ONLY shim of its contract functions. Never shipped.
cat > "$TMP/driver.sh" <<EOF
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
[ -f "$HERE/../factory-tasks.sh" ] && . "$HERE/../factory-tasks.sh"
. "$LAND"
if ! type _task_get >/dev/null 2>&1; then
  _plan_dir() { printf '%s/plans/%s' "\$OSRC_HOME" "\$1"; }
  _plan_resolve() { local p="\${1:-}"; [ -n "\$p" ] || p="\$(cat "\$OSRC_HOME/plans/current" 2>/dev/null)"; [ -n "\$p" ] || die "no plan"; printf '%s' "\$p"; }
  _task_get() { cat "\$(_plan_dir "\$1")/tasks/\$2.json" 2>/dev/null; }
  _task_update() { local f flt; f="\$(_plan_dir "\$1")/tasks/\$2.json"; flt="\$3"; shift 3
    jq "\$@" "\$flt | .updated=\"now\"" "\$f" > "\$f.tmp" && mv "\$f.tmp" "\$f"; }
  _task_event() { jq -cn --arg t "\$2" --arg e "\$3" --arg n "\${4:-}" '{task:\$t,event:\$e,note:\$n}' >> "\$(_plan_dir "\$1")/events.jsonl"; }
fi
"\$@"
EOF
ST="$TMP/state"; mkdir -p "$ST/jobs"
drv() { OSRC_HOME="$ST" bash "$TMP/driver.sh" "$@"; }

REPO="$TMP/repo"
mkdir -p "$REPO"; git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name t
printf 'line1\nline2\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -qm init
PLAN=p; PD="$ST/plans/$PLAN"; mkdir -p "$PD/tasks"; echo "$PLAN" > "$ST/plans/current"
jq -cn --arg r "$REPO" '{schema:1,name:"p",goal:"g",repo:$r,base_branch:"main",created:"x",updated:"x"}' > "$PD/plan.json"

# mk_task <tid> <shape> <check> [title] -> job "j-<tid>" with a worker worktree on branch outsourcerer/j-<tid>
mk_task() {
  local tid="$1" shape="$2" check="$3" title="${4:-task $1}" jid="j-$1" wt="" br="" base
  base="$(git -C "$REPO" rev-parse main)"
  mkdir -p "$ST/jobs/$jid"; echo done > "$ST/jobs/$jid/status"
  if [ "$shape" = ship ]; then
    wt="$REPO/.outsourcerer/worktrees/$jid"; br="outsourcerer/$jid"
    git -C "$REPO" worktree add -q -b "$br" "$wt" "$base" >/dev/null 2>&1
    jq -cn --arg p "$wt" --arg b "$br" --arg s "$base" '{path:$p,branch:$b,base_sha:$s,head_sha:$s,dirty:false,ahead:0}' > "$ST/jobs/$jid/worktree.json"
  fi
  jq -cn --arg id "$tid" --arg sh "$shape" --arg c "$check" --arg t "$title" --arg j "$jid" --arg w "$wt" --arg b "$br" --arg s "$base" \
    '{schema:1,id:$id,plan:"p",title:$t,shape:$sh,state:"running",deps:[],prompt:"x",spec:"",check:$c,verb:"edit",model:"",provider:"",
      deliver:"local",retries:1,attempts:1,job:$j,jobs:[$j],worktree:$w,branch:$b,base_sha:$s,head_sha:"",
      hold:{reason:"",until:"",answer:""},result:"",evidence:"",flow:{name:"",stage:""},created:"x",updated:"x"}' > "$PD/tasks/$tid.json"
}
wt_of() { echo "$REPO/.outsourcerer/worktrees/j-$1"; }
commit_in() { # <tid> <file> <content>
  local w; w="$(wt_of "$1")"; printf '%s\n' "$3" > "$w/$2"; git -C "$w" add "$2"; git -C "$w" commit -qm "work $1 $2"
}
tfield() { jq -r "$2" "$PD/tasks/$1.json"; }
efield() { jq -r "$2" "$PD/tasks/$1/evidence.json" 2>/dev/null; }
no_land_wt() { ! git -C "$REPO" worktree list | grep -q '/land-'; }

# ---------------- done contract: scout ----------------
mk_task t1 scout ""
printf 'the answer is 42\n' > "$ST/jobs/j-t1/last.txt"
out="$(drv _factory_done_check p t1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$PD/tasks/t1/report.md" ] && grep -q 42 "$PD/tasks/t1/report.md" && [ "$(efield t1 .verdict)" = done ] \
  && ok "scout: finished job with a result passes and the report is saved" || bad "scout pass (rc=$rc out=$out)"
[ "$(tfield t1 .evidence)" = "$PD/tasks/t1/evidence.json" ] && ok "scout: evidence path recorded on the task" || bad "scout evidence path not recorded"
mk_task t2 scout ""
: > "$ST/jobs/j-t2/last.txt"
out="$(drv _factory_done_check p t2)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'no result' && [ "$(efield t2 .verdict)" = not_done ] \
  && ok "scout: empty result is not done" || bad "scout empty result (rc=$rc out=$out)"
echo failed > "$ST/jobs/j-t2/status"; echo "x" > "$ST/jobs/j-t2/last.txt"
out="$(drv _factory_done_check p t2)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'status: failed' && ok "scout: failed job is not done" || bad "scout failed job (rc=$rc out=$out)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && ok "done check prints exactly one line" || bad "done check printed more than one line"

# ---------------- done contract: ship refusals ----------------
mk_task t3 ship ""
out="$(drv _factory_done_check p t3)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'no commits' && ok "ship: no commits -> refused" || bad "ship no commits (rc=$rc out=$out)"

mk_task t4 ship ""
commit_in t4 b.txt b; echo dirty >> "$(wt_of t4)/a.txt"
out="$(drv _factory_done_check p t4)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'uncommitted' && ok "ship: dirty worktree -> refused" || bad "ship dirty (rc=$rc out=$out)"

mk_task t5 ship ""
git -C "$(wt_of t5)" checkout -q --detach; commit_in t5 c.txt c
out="$(drv _factory_done_check p t5)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'not on any branch' && ok "ship: detached-only head -> refused" || bad "ship detached (rc=$rc out=$out)"

mk_task t6 ship "false"
commit_in t6 d.txt d
out="$(drv _factory_done_check p t6)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'check failed' && [ "$(efield t6 .check.rc)" = 1 ] \
  && ok "ship: failing check -> refused, rc in evidence" || bad "ship check fail (rc=$rc out=$out)"
echo "running" > "$ST/jobs/j-t6/status"
out="$(drv _factory_done_check p t6)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'not finished' && ok "ship: unfinished job -> refused" || bad "ship unfinished job (rc=$rc out=$out)"

mk_task t7 ship "true"
commit_in t7 cfg.txt "token=gh""p_$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)"
out="$(drv _factory_done_check p t7)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'secret' && [ "$(efield t7 .secret_scan)" = blocked ] \
  && ok "ship: secret in base..head diff -> refused" || bad "ship secret (rc=$rc out=$out)"
out="$(drv cmd_land t7 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not landing' && ok "land refuses when the done contract fails" || bad "land with failing contract (rc=$rc)"

# ---------------- happy path ----------------
mk_task t8 ship "test -f e.txt" "add e"
commit_in t8 e.txt e
before="$(git -C "$REPO" rev-parse main)"; head8="$(git -C "$(wt_of t8)" rev-parse HEAD)"
out="$(drv _factory_done_check p t8)"; rc=$?
[ "$rc" = 0 ] && [ "$(efield t8 .verdict)" = done ] && [ "$(efield t8 .head_sha)" = "$head8" ] && [ "$(efield t8 .check.rc)" = 0 ] \
  && [ "$(tfield t8 .head_sha)" = "$head8" ] && ok "ship: committed, clean, on a branch, check green -> done (+evidence)" || bad "ship done (rc=$rc out=$out)"
for k in task shape job base_sha head_sha check secret_scan verdict reason ts; do
  jq -e --arg k "$k" 'has($k)' "$PD/tasks/t8/evidence.json" >/dev/null || { bad "evidence missing key $k"; break; }
done && ok "evidence.json carries every contract key"
out="$(drv cmd_land t8 2>&1)"; rc=$?
after="$(git -C "$REPO" rev-parse main)"
[ "$rc" = 0 ] && [ "$after" != "$before" ] && [ "$(git -C "$REPO" log -1 --format=%s main)" = "land(p/t8): add e" ] \
  && [ "$(git -C "$REPO" rev-parse main^1)" = "$before" ] && [ "$(git -C "$REPO" rev-parse main^2)" = "$head8" ] \
  && ok "land: no-ff merge with the contract message, target fast-forwarded" || bad "land happy path (rc=$rc out=$out)"
[ -f "$REPO/e.txt" ] && [ -z "$(git -C "$REPO" status --porcelain -uno)" ] && ok "land: the checked-out target tree was updated cleanly" || bad "checkout not updated"
[ "$(tfield t8 .landed)" = true ] && [ "$(tfield t8 .state)" = done ] && [ "$(tfield t8 .landed_sha)" = "$after" ] \
  && [ "$(efield t8 .land.verdict)" = landed ] && [ "$(efield t8 .land.merged_sha)" = "$after" ] \
  && ok "land: task marked landed with evidence" || bad "landed bookkeeping"
no_land_wt && ok "land: integration worktree removed" || bad "integration worktree left behind"
[ -d "$(wt_of t8)" ] && ok "land: worker worktree left for cleanup" || bad "worker worktree removed by land"
out="$(drv cmd_land t8 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'already landed' && ok "land: second land of a landed task is a no-op" || bad "re-land (rc=$rc)"

# land into a branch that is NOT checked out anywhere (update-ref path)
git -C "$REPO" branch rel main
mk_task t9 ship "" "rel work"
commit_in t9 r.txt r
out="$(drv cmd_land t9 --into rel 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$REPO" log -1 --format=%s rel)" = "land(p/t9): rel work" ] && [ "$(git -C "$REPO" rev-parse main)" = "$after" ] \
  && ok "land --into: moves a branch that is not checked out, main untouched" || bad "land --into (rc=$rc out=$out)"

# ---------------- conflict ----------------
mk_task t10 ship ""
commit_in t10 a.txt "worker line"
printf 'main line\n' > "$REPO/a.txt"; git -C "$REPO" commit -qam "main edits a"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t10 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'conflicts with main in: a.txt' && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ -z "$(git -C "$REPO" status --porcelain -uno)" ] && [ "$(efield t10 .land.verdict)" = conflict ] \
  && ok "land: merge conflict aborts cleanly, target untouched" || bad "conflict (rc=$rc out=$out)"
no_land_wt && ok "land: no integration worktree left after a conflict" || bad "worktree left after conflict"
grep -q '"land_conflict"' "$PD/events.jsonl" 2>/dev/null && ok "land: conflict recorded as a task event" || bad "conflict event missing"

# ---------------- merged result breaks the check ----------------
CHK='! { [ -f x.txt ] && [ -f y.txt ]; }'
mk_task t11 ship "$CHK"
commit_in t11 x.txt x
printf 'y\n' > "$REPO/y.txt"; git -C "$REPO" add y.txt; git -C "$REPO" commit -qm "main adds y"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t11 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'check fails' && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(tfield t11 .state)" = failed ] && [ "$(tfield t11 .result)" = "merge breaks check" ] && [ "$(tfield t11 .landed)" != true ] \
  && [ "$(efield t11 .land.verdict)" = check_failed ] \
  && ok "land: merged result breaks check -> target untouched, task failed" || bad "merge breaks check (rc=$rc out=$out)"
no_land_wt && ok "land: no integration worktree left after a red check" || bad "worktree left after red check"
grep -q '"kind":"land"' "$ST/wake-queue.jsonl" 2>/dev/null && ok "land: red check queued a wake event" || bad "wake event missing"

# ---------------- target checked out dirty ----------------
mk_task t12 ship "" "dirty target"
commit_in t12 z.txt z
echo "local edit" >> "$REPO/a.txt"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t12 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'uncommitted changes' && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && grep -q 'local edit' "$REPO/a.txt" && [ "$(tfield t12 .landed)" != true ] \
  && ok "land: refuses to fast-forward a dirty checkout, nothing clobbered" || bad "dirty target (rc=$rc out=$out)"
git -C "$REPO" checkout -q -- a.txt

# ---------------- dry run ----------------
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t12 --dry-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'dry run' && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(tfield t12 .landed)" != true ] && [ "$(efield t12 .land.mode)" = dry-run ] && no_land_wt \
  && ok "land --dry-run: merges + checks in scratch, moves nothing" || bad "dry run (rc=$rc out=$out)"

# ---------------- serialized (two concurrent lands) ----------------
cat > "$TMP/slowcheck.sh" <<EOF
case "\$PWD" in */land-*) echo S >> "$TMP/seq"; sleep 2; echo E >> "$TMP/seq" ;; esac
exit 0
EOF
: > "$TMP/seq"
mk_task t13 ship "bash $TMP/slowcheck.sh" "c13"; commit_in t13 f13.txt a
mk_task t14 ship "bash $TMP/slowcheck.sh" "c14"; commit_in t14 f14.txt b
( drv cmd_land t13 > "$TMP/o13" 2>&1; echo $? > "$TMP/r13" ) &
( drv cmd_land t14 > "$TMP/o14" 2>&1; echo $? > "$TMP/r14" ) &
wait
[ "$(cat "$TMP/r13")" = 0 ] && [ "$(cat "$TMP/r14")" = 0 ] && [ "$(tr -d '\n' < "$TMP/seq")" = SESE ] \
  && git -C "$REPO" merge-base --is-ancestor "$(git -C "$(wt_of t13)" rev-parse HEAD)" main \
  && git -C "$REPO" merge-base --is-ancestor "$(git -C "$(wt_of t14)" rev-parse HEAD)" main \
  && ok "land: two concurrent lands serialize and both land" || bad "concurrent lands (r13=$(cat "$TMP/r13") r14=$(cat "$TMP/r14") seq=$(tr -d '\n' < "$TMP/seq"))"
cat "$TMP/o13" "$TMP/o14" | grep -q 'waiting in the merge queue' && ok "land: the waiter says who holds the queue" || bad "no waiting message"

# ---------------- lock: live holder times out; dead holder is reclaimed ----------------
LK="$(OSRC_HOME="$ST" bash "$TMP/driver.sh" _land_lock_dir "$(cd "$REPO" && pwd -P)")"
mk_task t15 ship "" "lock"; commit_in t15 g.txt g
sleep 60 & live=$!
mkdir -p "$LK"; printf '%s %s\n' "$live" "$(OSRC_HOME="$ST" bash "$TMP/driver.sh" _pid_start_identity "$live")" > "$LK/owner"; echo "land other" > "$LK/holder"
out="$(OSRC_LAND_LOCK_WAIT=2 drv cmd_land t15 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'gave up after 2s' && [ "$(tfield t15 .landed)" != true ] \
  && ok "land: bounded wait on a live holder, clear timeout" || bad "lock timeout (rc=$rc out=$out)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
out="$(OSRC_LAND_LOCK_WAIT=5 drv cmd_land t15 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t15 .landed)" = true ] && [ ! -d "$LK" ] && ok "land: a dead holder's lock is reclaimed" || bad "stale lock reclaim (rc=$rc out=$out)"

# ---------------- --pr via fake gh + local bare origin ----------------
git init -q --bare "$TMP/origin.git"; git -C "$REPO" remote add origin "$TMP/origin.git"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/gh.args"
echo "https://github.com/example/repo/pull/7"
EOF
chmod +x "$TMP/bin/gh"
mk_task t16 ship "test -f h.txt" "pr work"; commit_in t16 h.txt h
m="$(git -C "$REPO" rev-parse main)"; h16="$(git -C "$(wt_of t16)" rev-parse HEAD)"
out="$(PATH="$TMP/bin:$PATH" drv cmd_land t16 --pr 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$TMP/origin.git" rev-parse refs/heads/outsourcerer/j-t16 2>/dev/null)" = "$h16" ] \
  && grep -q -- '--base main' "$TMP/gh.args" && grep -q -- '--head outsourcerer/j-t16' "$TMP/gh.args" \
  && [ "$(tfield t16 .pr)" = "https://github.com/example/repo/pull/7" ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(efield t16 .land.verdict)" = pr_opened ] && ok "land --pr: pushes the branch, opens the PR, target not moved" || bad "land --pr (rc=$rc out=$out)"

# ---------------- bare job id (ad-hoc fanout/bg worktree job) ----------------
mk_task t17 ship "" "adhoc"; commit_in t17 k.txt k
out="$(drv cmd_land j-t17 --check 'test -f k.txt' 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$REPO" log -1 --format=%s main)" = "land(j-t17): outsourcerer/j-t17" ] \
  && [ "$(jq -r .land.verdict "$ST/jobs/j-t17/evidence.json")" = landed ] && [ "$(jq -r .check.rc "$ST/jobs/j-t17/evidence.json")" = 0 ] \
  && ok "land <job-id> --check: lands an ad-hoc worktree job, evidence in the job dir" || bad "bare job land (rc=$rc out=$out)"
out="$(drv cmd_land nope-123 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no task or job' && ok "land: unknown id says what to do" || bad "unknown id (rc=$rc)"

echo
echo "factory land: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
