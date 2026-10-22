#!/usr/bin/env bash
# test_factory_flow.sh -- Track D: the `plan run` scheduler and `flow` expansion.
# The task store (Track B) and done contract / land (Track C) are SHIMMED here, in the test only,
# against the contract's function names and data model. Jobs are fake job dirs (status files),
# never real model calls.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
FLOW="$HERE/../factory-flow.sh"
[ -f "$SRC" ] && [ -f "$FLOW" ] || { echo "FAIL: cannot find $SRC or $FLOW"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-factory-flow.XXXXXX")"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME/jobs"
SLEEPERS=""
trap 'for p in $SLEEPERS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
. "$FLOW"
export OSRC_HEARTBEAT_DISABLED=1

# ------------------------------------------------------------------ task store (Track B)
# When factory-tasks.sh sits next to the engine (after integration) the REAL task store is used and
# only its launch seam (_task_bg_launch) is faked. Otherwise these shims mirror B's documented API:
# _task_new, _task_view (.derived/.blocked_by), _task_update (guarded, held/failed -> wake),
# _task_dispatch (claim + attempts+1, brief with "Earlier attempt", launch failure -> task failed).
REAL_B=0
if [ -f "$HERE/../factory-tasks.sh" ]; then . "$HERE/../factory-tasks.sh"; REAL_B=1; fi
echo "INFO: task store under test: $([ "$REAL_B" = 1 ] && echo 'real factory-tasks.sh' || echo 'test shims')"
if [ "$REAL_B" = 0 ]; then
_plan_dir() { printf '%s\n' "$OSRC_HOME/plans/$1"; }
_plan_resolve() {
  local p="${1:-}"; [ -n "$p" ] || p="$(cat "$OSRC_HOME/plans/current" 2>/dev/null)"
  [ -n "$p" ] || die "no plan"; printf '%s\n' "$p"
}
_task_get() { cat "$OSRC_HOME/plans/$1/tasks/$2.json" 2>/dev/null; }
_task_update() {
  local plan="$1" tid="$2" filter="$3" f old new tmp; shift 3
  f="$OSRC_HOME/plans/$plan/tasks/$tid.json"; [ -f "$f" ] || return 1
  old="$(jq -r .state "$f")"
  tmp="$(jq -e "$@" "($filter) | .updated = \"now\"" "$f" 2>/dev/null)" || return 1
  printf '%s\n' "$tmp" > "$f.tmp" && mv -f "$f.tmp" "$f" || return 1
  new="$(jq -r .state "$f")"
  if [ "$old" != "$new" ]; then
    printf '{"task":"%s","event":"state","from":"%s","to":"%s"}\n' "$tid" "$old" "$new" >> "$OSRC_HOME/plans/$plan/events.jsonl"
    case "$new" in held|failed)
      _wake_append "$(jq -cn --arg id "factory.$plan.$tid.$new.$RANDOM" --arg p "$plan" --arg t "$tid" --arg s "$new" \
        '{event_id:$id,kind:"factory-task",plan:$p,task:$t,state:"blocked",task_state:$s,task_summary:"x"}')" >/dev/null 2>&1 ;;
    esac
  fi
  return 0
}
_task_list() { local d="$OSRC_HOME/plans/$1/tasks"; if ls "$d"/t*.json >/dev/null 2>&1; then jq -s 'sort_by(.id | ltrimstr("t") | tonumber)' "$d"/t*.json; else echo '[]'; fi; }
_task_view() {
  _task_list "$1" | jq -c '(map({key: .id, value: .state}) | from_entries) as $s
    | map(. as $t | ([($t.deps // [])[] | {id: ., state: ($s[.] // "missing")} | select(.state != "done")]) as $bl
          | . + {blocked_by: $bl, derived: (if $t.state == "todo" then (if ($bl | length) == 0 then "ready" else "blocked" end) else $t.state end)})'
}
_task_ready() { _task_view "$1" | jq -r '.[] | select(.derived == "ready") | .id'; }
_task_event() { printf '{"task":"%s","event":"%s","note":"%s"}\n' "$2" "$3" "${4:-}" >> "$OSRC_HOME/plans/$1/events.jsonl"; }
_task_new() {
  local plan="$1" fields="$2" n d
  d="$OSRC_HOME/plans/$plan/tasks"; mkdir -p "$d"
  for x in $(printf '%s' "$fields" | jq -r '(.deps // [])[]'); do [ -f "$d/$x.json" ] || { echo "missing dep $x" >&2; return 1; }; done
  n="$(ls "$d" | sed -n 's/^t\([0-9]*\)\.json$/\1/p' | sort -n | tail -1)"; n="t$(( ${n:-0} + 1 ))"
  jq -n --arg id "$n" --arg plan "$plan" --argjson f "$fields" '
    {schema:1,title:"",shape:"scout",state:"todo",deps:[],prompt:"",spec:"",check:"",verb:"",model:"",provider:"",deliver:"local",
     retries:1,attempts:0,job:"",jobs:[],worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},
     result:"",evidence:"",flow:{name:"",stage:""}} * $f | .id = $id | .plan = $plan
    | if .prompt == "" then .prompt = .title else . end' > "$d/$n.json" || return 1
  mkdir -p "$d/$n"; echo "$n"
}
_task_brief() {
  local plan="$1" tid="$2" t f
  t="$(_task_get "$plan" "$tid")"; f="$OSRC_HOME/plans/$plan/tasks/$tid/brief.md"; mkdir -p "${f%/*}"
  { printf '%s\n\n' "$(printf '%s' "$t" | jq -r .prompt)"
    [ "$(printf '%s' "$t" | jq -r .hold.answer)" != "" ] && printf '## Decision from the captain\n\n%s\n\n' "$(printf '%s' "$t" | jq -r .hold.answer)"
    if [ "$(printf '%s' "$t" | jq -r .attempts)" -gt 0 ] && [ -n "$(printf '%s' "$t" | jq -r .result)" ]; then
      printf '## Earlier attempt\n\nWhat went wrong: %s\n' "$(printf '%s' "$t" | jq -r .result)"; fi; } > "$f"
  echo "$f"
}
_task_dispatch() {
  local plan="$1" tid="$2" jid
  _task_update "$plan" "$tid" 'if .state != "todo" then error("no") else .state = "running" | .attempts += 1 | .job = "" end' || { echo "not ready" >&2; return 1; }
  _task_brief "$plan" "$tid" >/dev/null
  jid="$( export OSRC_TASK_REF="$plan/$tid"; _task_bg_launch "$PWD" run "x" )" || {
    _task_update "$plan" "$tid" '.state = "failed" | .result = $r' --arg r "the worker did not launch"; echo "launch failed" >&2; return 1; }
  _task_update "$plan" "$tid" '.job = $j | .jobs += [$j]' --arg j "$jid"
  echo "$jid"
}
fi
# The launch seam (both modes): a FAKE job whose status comes from $TMP/outcomes/<tid>, one line per
# attempt (done | failed | blocked | running). Copies the brief the worker would have received.
_task_bg_launch() {
  local ref="${OSRC_TASK_REF:-}" plan tid n out job
  plan="${ref%%/*}"; tid="${ref#*/}"
  [ -f "$TMP/dispatch-refuse-$tid" ] && { echo "ERROR: lane is down for $tid" >&2; return 1; }
  n=$(( $(cat "$TMP/count-$plan-$tid" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/count-$plan-$tid"
  out="$(sed -n "${n}p" "$TMP/outcomes/$tid" 2>/dev/null)"; [ -n "$out" ] || out=done
  job="$(date +%Y%m%d-%H%M%S)-$plan$tid$n$RANDOM"; job="$(printf '%s' "$job" | tr -cd '0-9A-Za-z-')"
  mkdir -p "$OSRC_JOBS/$job"
  printf '%s\n' "$out" > "$OSRC_JOBS/$job/status"
  date +%s > "$OSRC_JOBS/$job/started_at"
  [ "$out" = running ] && printf '%s\n' "$$" > "$OSRC_JOBS/$job/pid"
  [ "$out" = failed ] && printf 'exit-nonzero:rc=1\n' > "$OSRC_JOBS/$job/reason"
  printf 'result of %s attempt %s\n%s\n' "$tid" "$n" "$(cat "$TMP/lasttxt-$tid" 2>/dev/null)" > "$OSRC_JOBS/$job/last.txt"
  cp "$OSRC_HOME/plans/$plan/tasks/$tid/brief.md" "$TMP/brief-$plan-$tid-$n" 2>/dev/null
  echo "$job"
}
# ------------------------------------------------------------------ Track C shims (test only, both modes:
# the real done contract needs real worktrees + commits; track C tests it on its own)
_factory_done_check() {
  if [ -f "$TMP/donefail-$2" ]; then echo "no commits beyond base"; return 1; fi
  echo "done: job finished"; return 0
}
cmd_land() { echo "$1" >> "$TMP/landed"; [ -f "$TMP/landfail-$1" ] && { echo "merge breaks check"; return 1; }; echo "landed $1"; return 0; }

REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
REPO="$(cd "$REPO" && pwd -P)"
mkplan() {   # <plan> then lines "tid|deps-csv|shape|retries"
  local plan="$1" line tid deps shape retries
  mkdir -p "$OSRC_HOME/plans/$plan/tasks"
  jq -n --arg n "$plan" --arg r "$REPO" --arg b "$(git -C "$REPO" symbolic-ref --short HEAD)" '{schema:1,name:$n,goal:"g",repo:$r,base_branch:$b,created:"x",updated:"x"}' > "$OSRC_HOME/plans/$plan/plan.json"
  shift
  for line in "$@"; do
    IFS='|' read -r tid deps shape retries <<EOF
$line
EOF
    jq -n --arg id "$tid" --arg plan "$plan" --arg deps "$deps" --arg shape "${shape:-scout}" --argjson r "${retries:-1}" \
      '{schema:1,id:$id,plan:$plan,title:("task " + $id),shape:$shape,state:"todo",deps:($deps | split(",") | map(select(. != ""))),
        prompt:("do " + $id),spec:"",check:"",verb:"run",model:"",provider:"",deliver:"local",retries:$r,attempts:0,
        job:"",jobs:[],worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},result:"",evidence:"",
        flow:{name:"",stage:""},created:"x",updated:"x"}' > "$OSRC_HOME/plans/$plan/tasks/$tid.json"
  done
}
st() { _task_get "$1" "$2" | jq -r .state; }
wakes() { cat "$OSRC_WAKE_QUEUE" 2>/dev/null | grep -c "$1" | tr -d ' '; }
twakes() { cat "$OSRC_WAKE_QUEUE" 2>/dev/null | grep '"kind":"factory-task"' | grep "\"plan\":\"$1\"" | grep "\"task\":\"$2\"" | grep -c "\"task_state\":\"$3\"" | tr -d ' '; }
mkdir -p "$TMP/outcomes"

# ================================================================== scheduler
# 1. success chain, deps respected, exit 0, finished wake
mkplan p1 't1||scout|1' 't2|t1|scout|1'
out="$( cmd_plan_run p1 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(st p1 t1)" = done ] && [ "$(st p1 t2)" = done ] && ok "all tasks done -> exit 0" || bad "success chain rc=$rc t1=$(st p1 t1) t2=$(st p1 t2): $out"
[ "$(sed -n 1p "$OSRC_HOME/plans/p1/events.jsonl" | jq -r .task)" = t1 ] && ! grep -q '"task":"t2","event":"state","from":"todo","to":"running"' <<<"$(sed -n 1,2p "$OSRC_HOME/plans/p1/events.jsonl")" \
  && ok "t2 started only after t1 finished" || bad "dependency order not respected"
printf '%s' "$out" | grep -q "Captain's Call: 0 | Landed/Done: 2 | Underway: 0 | Next: 0 ready" && ok "four-bucket summary printed each tick" || bad "summary missing: $out"
printf '%s' "$out" | grep -q "stopped: p1 is finished (2 done)" && ok "plain stop reason on finish" || bad "finish reason: $out"
[ "$(wakes 'factory-finished')" = 1 ] && ok "plan finished -> one wake event" || bad "finished wake count $(wakes factory-finished)"
( cmd_plan_run p1 --once >/dev/null 2>&1 ); [ "$(wakes 'factory-finished')" = 1 ] && ok "re-running a finished plan does not re-wake" || bad "finished wake repeated"

# 2. failure -> retry -> success, reason lands in the next brief
mkplan p2 't1||scout|1'; printf 'failed\ndone\n' > "$TMP/outcomes/t1"
out="$( cmd_plan_run p2 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(st p2 t1)" = done ] && ok "failure then retry then success -> done" || bad "retry path rc=$rc state=$(st p2 t1): $out"
grep -q "previous attempt failed because job [0-9A-Za-z-]* ended failed (exit-nonzero:rc=1)" "$TMP/brief-p2-t1-2" \
  && ok "retry brief says why the previous attempt failed" || bad "retry brief: $(cat "$TMP/brief-p2-t1-2" 2>/dev/null)"
[ "$(grep -c 'previous attempt failed' "$TMP/brief-p2-t1-2")" = 1 ] && ! grep -q 'previous attempt failed' "$TMP/brief-p2-t1-1" \
  && ok "failure note appears once, only on the retry" || bad "failure note duplicated or early"
_task_get p2 t1 | jq -e '.result | startswith("previous attempt") | not' >/dev/null && ok "a passed retry replaces the failure note in .result" || bad "stale failure result: $(_task_get p2 t1 | jq -r .result)"

# 3. failure exhausted -> failed + hold reason + wake, exit 3
mkplan p3 't1||scout|1' 't2|t1|scout|1'; printf 'failed\nfailed\n' > "$TMP/outcomes/t1"
out="$( cmd_plan_run p3 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st p3 t1)" = failed ] && [ "$(st p3 t2)" = todo ] && ok "retries exhausted -> failed, exit 3" || bad "exhausted rc=$rc: $out"
_task_get p3 t1 | jq -e '.hold.reason | test("failed after 2 attempt")' >/dev/null && ok "captain hold reason recorded" || bad "no hold reason"
[ "$(twakes p3 t1 failed)" = 1 ] && ok "terminal failure -> exactly one wake (the task store's)" || bad "failure wakes: $(twakes p3 t1 failed)"
printf '%s' "$out" | grep -q "needs the captain.*failed: t1.*blocked: t2 waits on t1 (failed)" && ok "stop reason names failed and blocked work" || bad "stuck reason: $out"

# 4. blocked worker -> held + wake ; done check failure goes through retry
mkplan p4 't1||scout|0' 't2||ship|0'; printf 'blocked\n' > "$TMP/outcomes/t1"; touch "$TMP/donefail-t2"
out="$( cmd_plan_run p4 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st p4 t1)" = held ] && ok "blocked worker -> held for captain" || bad "blocked rc=$rc t1=$(st p4 t1)"
_task_get p4 t2 | jq -e '.state == "failed" and (.result | test("done check said no: no commits"))' >/dev/null && ok "done-check failure is a failure with its reason" || bad "donecheck: $(_task_get p4 t2)"
[ "$(twakes p4 t1 held)" = 1 ] && ok "held -> exactly one wake" || bad "held wakes: $(twakes p4 t1 held)"
rm -f "$TMP/donefail-t2"

# 5. max-parallel respected + --once exit 124
rm -f "$TMP"/outcomes/*
mkplan p5 't1||scout|1' 't2||scout|1' 't3||scout|1' 't4||scout|1'
for t in t1 t2 t3 t4; do echo running > "$TMP/outcomes/$t"; done
out="$( cmd_plan_run p5 --once --max-parallel 2 2>&1 )"; rc=$?
n_running="$(_task_list p5 | jq '[.[] | select(.state == "running")] | length')"
[ "$rc" = 124 ] && [ "$n_running" = 2 ] && ok "--max-parallel 2 starts two; --once exits 124 while work is underway" || bad "parallel rc=$rc running=$n_running: $out"
( cmd_plan_run p5 --once --max-parallel 2 >/dev/null 2>&1 )
[ "$(_task_list p5 | jq '[.[] | select(.state == "running")] | length')" = 2 ] && ok "a second tick does not exceed the cap" || bad "cap exceeded"
# finish the running jobs -> the next tick reconciles them and starts the rest
for j in $(_task_list p5 | jq -r '.[] | .job | select(. != "")'); do echo done > "$OSRC_JOBS/$j/status"; done
( cmd_plan_run p5 --once --max-parallel 2 >/dev/null 2>&1 )
[ "$(_task_list p5 | jq -r '[.[] | .state] | join(",")')" = "done,done,running,running" ] && ok "finished jobs reconcile and free slots" || bad "reconcile: $(_task_list p5 | jq -c '[.[]|.state]')"

# 6. run lock: a live driver blocks a second loop; a dead one is reclaimed
sleep 60 & SLP=$!; SLEEPERS="$SLEEPERS $SLP"
mkdir -p "$OSRC_HOME/plans/p5/run.lock"; printf '%s %s\n' "$SLP" "$(_pid_start_identity "$SLP")" > "$OSRC_HOME/plans/p5/run.lock/owner"
out="$( cmd_plan_run p5 --once 2>&1 )"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "already driving p5 (pid $SLP)" && ok "run lock refuses a second driver" || bad "lock rc=$rc: $out"
kill "$SLP" 2>/dev/null; wait "$SLP" 2>/dev/null
out="$( cmd_plan_run p5 --once 2>&1 )"; rc=$?
[ "$rc" != 1 ] && [ ! -d "$OSRC_HOME/plans/p5/run.lock" ] && ok "stale lock from a dead driver is reclaimed and released" || bad "stale lock rc=$rc: $out"

# 7. time cap -> exit 2 ; dispatch refusal -> failed + wake
mkplan p7b 't1||scout|1'; echo running > "$TMP/outcomes/t1"
# Fake clock: every `date +%s` advances two minutes (a file counter: calls run in subshells).
echo 0 > "$TMP/clock"
out="$( date() { if [ "${1:-}" = +%s ]; then local c; c=$(( $(cat "$TMP/clock") + 1 )); echo "$c" > "$TMP/clock"; echo $(( 1000000 + c * 120 )); else command date "$@"; fi; }
        cmd_plan_run p7b --interval 1 --max-minutes 1 2>&1 )"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "time cap of 1 minutes reached" && ok "runaway guard: time cap exits 2 with a plain reason" || bad "time cap rc=$rc: $out"
mkplan p8 't1||scout|1'; touch "$TMP/dispatch-refuse-t1"
out="$( cmd_plan_run p8 --once 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st p8 t1)" = failed ] && printf '%s' "$out" | grep -q "could not start" && ok "launch failure fails closed (task store marks it failed)" || bad "dispatch refusal rc=$rc: $out"
rm -f "$TMP/dispatch-refuse-t1"
mkplan p9
out="$( cmd_plan_run p9 --once 2>&1 )"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "has no tasks yet" && ok "empty plan stops with a plain reason" || bad "empty plan rc=$rc: $out"
( cmd_plan_run p9 --max-parallel 0 >/dev/null 2>&1 ); [ $? = 1 ] && ok "bad --max-parallel is refused" || bad "max-parallel 0 accepted"

# 8. auto-land lands done ship tasks once
rm -f "$TMP"/outcomes/* "$TMP/landed"
mkplan pl 't1||ship|1' 't2||scout|1'
( cmd_plan_run pl --interval 1 --auto-land >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t1 ] && ok "--auto-land lands the ship task only" || bad "auto-land rc=$rc landed=$(cat "$TMP/landed" 2>/dev/null)"

# ================================================================== flows
FLOWS_DIR="$HERE/../../references/flows"
out="$(cmd_flow ls)"
for f in council-build spec-build best-of-n; do printf '%s' "$out" | grep -q "^$f " || bad "flow ls missing $f"; done
printf '%s' "$out" | grep -q '^council-build *built-in' && ok "flow ls lists the shipped flows" || bad "flow ls: $out"
for f in council-build spec-build best-of-n; do ( _ff_flow_load "$f" >/dev/null 2>&1 ) || bad "shipped flow $f fails validation"; done
ok "shipped flows validate"
out="$(cmd_flow show council-build)"; printf '%s' "$out" | grep -q 'land  lands build' && ok "flow show renders stages" || bad "flow show: $(cmd_flow show council-build)"

# missing required var
out="$( cmd_flow run spec-build --plan fx0 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "needs --var goal=" && [ ! -d "$OSRC_HOME/plans/fx0" ] && ok "missing required var refused before any plan is made" || bad "missing var rc=$rc: $out"
out="$( cmd_flow run spec-build --plan fx0 --var goal=x --var chek=y 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "has no variable chek" && ok "unknown var (typo) refused" || bad "unknown var rc=$rc: $out"

# real expansion needs a repo for ship stages
mkdir -p "$TMP/norepo"
out="$( cd "$TMP/norepo" && GIT_CEILING_DIRECTORIES="$TMP" cmd_flow run spec-build --plan fx1 --var goal=add-x 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "needs a git repo" && ok "code-building flow outside a repo is refused" || bad "no-repo rc=$rc: $out"

out="$( cmd_flow run council-build --plan fx2 --repo "$REPO" --var goal="Add a login page" --var check="make test" 2>&1 )"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "next: .* plan run fx2" && ok "flow run creates tasks and prints the next command" || bad "council run rc=$rc: $out"
L="$(_task_list fx2)"
[ "$(printf '%s' "$L" | jq length)" = 6 ] && ok "council-build expands to 6 tasks" || bad "council count $(printf '%s' "$L" | jq length)"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "synthesize") | .deps == ["t1","t2"]' >/dev/null && ok "stage deps translate to tids" || bad "deps map: $(printf '%s' "$L" | jq -c '[.[]|{id,deps}]')"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "build") | .check == "make test" and .shape == "ship" and (.prompt | test("Add a login page"))' >/dev/null && ok "vars substituted into prompt and check" || bad "subst: $(printf '%s' "$L" | jq -c '.[3]')"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "land") | .land_target == "t4" and (.deps | index("t5")) != null and .gate == false' >/dev/null && ok "land stage targets the build tid after review" || bad "land stage: $(printf '%s' "$L" | jq -c '.[5]')"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "review") | .require_verdict == true and .model == "sol"' >/dev/null && ok "review stage requires a verdict on another family" || bad "review: $(printf '%s' "$L" | jq -c '.[4]')"
jq -e '.repo != "" and .goal == "Add a login page"' "$OSRC_HOME/plans/fx2/plan.json" >/dev/null && ok "plan created with repo and goal" || bad "plan.json: $(cat "$OSRC_HOME/plans/fx2/plan.json")"

# exclude list honored when _model_excluded exists
_model_excluded() { case "$1" in sol|opus) return 0 ;; esac; return 1; }
( cmd_flow run council-build --plan fx3 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
L="$(_task_list fx3)"
[ "$(printf '%s' "$L" | jq -r '[.[] | .model] | join(",")')" = "terra,gemini-pro,gemini-pro,glm-5-2,gemini-pro," ] && ok "excluded models skipped, next allowed fallback used" || bad "exclude: $(printf '%s' "$L" | jq -r '[.[]|.model]|join(",")')"
unset -f _model_excluded

# best-of-n with n=3: three candidates on different models, compare depends on all, pick is a hold gate
( cmd_flow run best-of-n --plan fx4 --repo "$REPO" --var goal=g --var n=3 >/dev/null 2>&1 )
L="$(_task_list fx4)"
[ "$(printf '%s' "$L" | jq '[.[] | select(.flow.stage | startswith("candidate-"))] | length')" = 3 ] && ok "best-of-n expands n=3 candidates" || bad "bon count: $(printf '%s' "$L" | jq -c '[.[]|.flow.stage]')"
[ "$(printf '%s' "$L" | jq -r '[.[0:3][] | .model] | join(",")')" = "glm-5-2,swe-1-7,kimi-k3" ] && ok "candidates rotate across models" || bad "bon models"
printf '%s' "$L" | jq -e '.[3].deps == ["t1","t2","t3"] and .[0].title == "Candidate 1 of 3: g"' >/dev/null && ok "compare depends on every candidate; {{i}}/{{n}} substituted" || bad "bon deps: $(printf '%s' "$L" | jq -c '.[3]')"
printf '%s' "$L" | jq -e '.[4].hold_after_deps == true and .[4].state == "todo" and .[4].deps == ["t4"]' >/dev/null && ok "hold stage is a todo with hold_after_deps" || bad "hold stage: $(printf '%s' "$L" | jq -c '.[4]')"
( cmd_flow run best-of-n --plan fx5 --repo "$REPO" --var goal=g --var n=abc >/dev/null 2>&1 ) && bad "non-numeric n accepted" || ok "non-numeric repeat count refused"

# hold stage at run time: after deps -> held + wake; after release -> done with the captain's answer
rm -f "$TMP"/outcomes/*
for t in t1 t2 t3 t4; do _task_update fx4 "$t" '.state = "done"'; done
out="$( cmd_plan_run fx4 --once 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st fx4 t5)" = held ] && _task_get fx4 t5 | jq -e '.hold_after_deps == false and .gate == true and (.hold.reason | test("captain"))' >/dev/null \
  && ok "decision gate becomes held once its deps are done" || bad "gate rc=$rc: $out $(_task_get fx4 t5)"
[ "$(twakes fx4 t5 held)" = 1 ] && ok "decision gate -> exactly one wake" || bad "gate wakes: $(twakes fx4 t5 held)"
_task_update fx4 t5 '.state = "todo" | .hold.answer = "t2"'
( cmd_plan_run fx4 --once >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && _task_get fx4 t5 | jq -e '.state == "done" and .result == "t2"' >/dev/null && ok "released gate completes with the captain's answer" || bad "release rc=$rc $(_task_get fx4 t5)"

# verdict gate: FAIL -> held; PASS -> done ; land stage lands its target
rm -f "$TMP/landed"
for t in t1 t2 t3 t4; do _task_update fx2 "$t" '.state = "done"'; done
echo "VERDICT: FAIL - skipped the tests" > "$TMP/lasttxt-t5"
( cmd_plan_run fx2 --interval 1 >/dev/null 2>&1 ); rc=$?
[ "$rc" = 3 ] && [ "$(st fx2 t5)" = held ] && [ "$(st fx2 t6)" = todo ] && ok "reviewer FAIL holds the review and blocks landing" || bad "verdict fail rc=$rc t5=$(st fx2 t5)"
_task_update fx2 t5 '.state = "todo" | .jobs = []'
echo "VERDICT: PASS" > "$TMP/lasttxt-t5"
( cmd_plan_run fx2 --interval 1 >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(st fx2 t6)" = done ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t4 ] && ok "reviewer PASS -> land stage lands the build" || bad "verdict pass rc=$rc t6=$(st fx2 t6) landed=$(cat "$TMP/landed" 2>/dev/null)"

# user flow overrides built-in by name
mkdir -p "$OSRC_HOME/flows"
cat > "$OSRC_HOME/flows/spec-build.json" <<'EOF'
{"name":"spec-build","description":"my override","vars":{"goal":"required"},
 "stages":[{"id":"only","title":"just {{goal}}","shape":"scout","verb":"research","model":"opus","prompt":"think about {{goal}}"}]}
EOF
out="$(cmd_flow ls)"; printf '%s\n' "$out" | grep -q '^spec-build *yours *my override' && ok "user flow overrides built-in in ls" || bad "override ls: $(cmd_flow ls)"
( cmd_flow run spec-build --plan fx6 --var goal=z >/dev/null 2>&1 )
[ "$(_task_list fx6 | jq length)" = 1 ] && ok "user flow overrides built-in in run (no repo needed for scouts)" || bad "override run"

# injection-safe substitution: quotes, $( ), backticks, {{other}} in values stay literal text
EVIL='he said "hi" '"'"'q'"'"' $(touch '"$TMP"'/pwned1) `touch '"$TMP"'/pwned2` {{goal}} \(.x)'
( cmd_flow run spec-build --plan fx7 --var goal="$EVIL" >/dev/null 2>&1 )
got="$(_task_get fx7 t1 | jq -r .prompt)"
[ "$got" = "think about $EVIL" ] && [ ! -e "$TMP/pwned1" ] && [ ! -e "$TMP/pwned2" ] && ok "var values are inserted literally, never executed or re-expanded" || bad "injection: got [$got]"
cat > "$OSRC_HOME/flows/badref.json" <<'EOF'
{"name":"badref","vars":{"goal":"required"},"stages":[{"id":"a","prompt":"{{goal}} {{nope}}"}]}
EOF
out="$( cmd_flow run badref --plan fx8 --var goal=x 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "uses {{nope}} but does not declare it" && ok "undeclared placeholder refused" || bad "badref rc=$rc: $out"
cat > "$OSRC_HOME/flows/cyc.json" <<'EOF'
{"name":"cyc","stages":[{"id":"a","prompt":"x","deps":["b"]},{"id":"b","prompt":"y"}]}
EOF
out="$( cmd_flow run cyc 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "depends on b, which is not an earlier stage" && ok "forward/cyclic deps refused" || bad "cyc rc=$rc: $out"
( cmd_flow run '../etc/passwd' >/dev/null 2>&1 ) && bad "path-like flow name accepted" || ok "path-like flow names refused"
out="$( cmd_flow run council-build --plan fx9 --var goal=g --dry-run 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ ! -d "$OSRC_HOME/plans/fx9" ] && printf '%s' "$out" | grep -q "land  lands build" && ok "--dry-run previews without writing" || bad "dry-run rc=$rc: $out"

# bearings hook: one line per active plan
out="$(_factory_plans_digest)"
printf '%s' "$out" | grep -q '^plan p3: 1 need you' && ! printf '%s' "$out" | grep -q '^plan p1:' && ok "digest shows active plans, skips finished ones" || bad "digest: $out"

echo "---"
echo "test_factory_flow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
