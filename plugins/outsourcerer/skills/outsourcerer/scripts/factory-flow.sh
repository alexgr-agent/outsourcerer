# factory-flow.sh -- Outsourcerer software factory, Track D: the scheduler (`plan run`) and
# flows (`flow ls|show|run`). Sourced by outsourcerer.sh near the end of its definitions; it
# defines functions only and runs nothing at source time.
#
# Depends on (never re-implements):
#   Track B (factory-tasks.sh): _plan_dir _plan_resolve _task_get _task_update _task_list
#                               _task_view _task_ready _task_dispatch _task_event _task_new
#                               (_plan_cli_new, _task_finish_from_output when present)
#   Wakes: the task store already sends a wake whenever a task turns held or failed, so this file
#   only adds the "plan finished" wake (never a second one for held/failed).
#   Track C (factory-land.sh):  _factory_done_check cmd_land
#   Track A (optional):         _model_excluded <model>  (rc0 = excluded)
#   Engine:                     die have cmd_wait _reconcile_status _wake_append _mkdir_claim
#                               _pid_start_identity
#
# Extra task fields this track writes (the task store keeps unknown fields as-is):
#   hold_after_deps (bool)  -- a flow stage with "hold":true. Created as state todo; when its deps
#                              finish the scheduler flips it to held (decision for the captain) and
#                              clears the flag.
#   gate (bool)             -- a hold stage with no prompt: a pure decision. After `task release
#                              --answer`, the scheduler marks it done with the answer as its result
#                              (`task release --done` does the same by hand). A hold stage WITH a
#                              prompt is dispatched after release, with the answer in its brief.
#   land_target (tid)       -- a flow stage with "land":"<stage>". No worker runs: when ready, the
#                              scheduler lands the target task through `land` and records the outcome.
#   require_verdict (bool)  -- a flow stage with "verdict":true (a reviewer). Its output must carry a
#                              line `VERDICT: PASS`; FAIL or no verdict holds it for the captain.
# bash 3.2 compatible: no associative arrays, no mapfile, no ${x,,}.

_FF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ---------------------------------------------------------------- small helpers

_ff_need_jq() { have jq || die "the factory needs jq; install it (brew install jq, or apt install jq) and try again"; }
_ff_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ff_name_ok() { case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
_ff_need_fns() {   # <fn>... -> die naming the first missing piece of the factory
  local f
  for f in "$@"; do
    declare -F "$f" >/dev/null 2>&1 || die "this build is missing part of the factory ($f); reinstall outsourcerer or update it"
  done
}

# _ff_wake <plan> <tid|-> <kind> <summary>: queue a wake event for the heartbeat. Best-effort: a
# full or locked wake queue never stops the scheduler. Event ids stay inside the queue's charset.
_ff_wake() {
  local plan="$1" tid="$2" kind="$3" summary="$4" id
  declare -F _wake_append >/dev/null 2>&1 || return 0
  id="factory.$(printf '%s' "$plan" | tr -c 'A-Za-z0-9._-' '_').$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').$kind.$(date +%s).$$"
  _wake_append "$(jq -cn --arg event_id "$id" --arg kind "factory-$kind" --arg plan "$plan" --arg task "$tid" \
      --arg s "$summary" '{event_id:$event_id,kind:$kind,state:"blocked",plan:$plan,task:$task,task_summary:$s}')" \
    >/dev/null 2>&1 || true
}

_ff_event() { declare -F _task_event >/dev/null 2>&1 && _task_event "$@" >/dev/null 2>&1; return 0; }

# ---------------------------------------------------------------- run lock (one driver per plan)
# mkdir lock with "pid start-identity" owner record, the house pattern. A lock whose owner is dead
# (or whose pid was recycled by another process) is reclaimed; a live owner is never robbed.
_FF_LOCK=""
_FF_LOCK_HOLDER=""
_ff_lock_acquire() {   # <lockdir> -> 0 claimed | 1 held by a live driver (pid in _FF_LOCK_HOLDER)
  local dir="$1" own="$1/owner" me ident opid oident cur tries=0
  me="${BASHPID:-$$}"
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    if _mkdir_claim "$dir"; then
      ident="$(_pid_start_identity "$me" 2>/dev/null)"
      printf '%s %s\n' "$me" "$ident" > "$dir/.own.$me" 2>/dev/null && mv -f "$dir/.own.$me" "$own" 2>/dev/null
      _FF_LOCK="$dir"; return 0
    fi
    opid=""; oident=""
    [ -f "$own" ] && read -r opid oident < "$own" 2>/dev/null
    if [ -n "$opid" ]; then
      if kill -0 "$opid" 2>/dev/null; then
        cur="$(_pid_start_identity "$opid" 2>/dev/null)"
        if [ -z "$oident" ] || [ -z "$cur" ] || [ "$cur" = "$oident" ]; then
          _FF_LOCK_HOLDER="$opid"; return 1
        fi
      fi
      rm -rf "$dir" 2>/dev/null   # owner is dead or its pid was reused: stale
    elif [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$dir" 2>/dev/null   # ownerless for over a minute: the claimer died mid-claim
    else
      _FF_LOCK_HOLDER="unknown"; return 1
    fi
  done
  _FF_LOCK_HOLDER="unknown"; return 1
}
_ff_lock_release() {
  local opid=""
  [ -n "$_FF_LOCK" ] || return 0
  [ -f "$_FF_LOCK/owner" ] && read -r opid _ < "$_FF_LOCK/owner" 2>/dev/null
  [ "$opid" = "${BASHPID:-$$}" ] && rm -rf "$_FF_LOCK" 2>/dev/null
  _FF_LOCK=""
  return 0
}

# ---------------------------------------------------------------- scheduler: reconcile

# _ff_job_outcome <job>: sets _FF_OUT (ok|live|blocked|failed) and _FF_REASON. Reads job state the
# same way `wait` does (cmd_wait --for 0: done|done? = 0, blocked = 3, failure or dead orphan = 1,
# still live = 124), so the scheduler and `wait` can never disagree about a job.
_FF_OUT=""; _FF_REASON=""
_ff_job_outcome() {
  local job="$1" rc st r
  _FF_OUT=failed; _FF_REASON=""
  if [ -z "$job" ]; then _FF_REASON="no job was recorded for it"; return 0; fi
  if [ ! -d "$OSRC_JOBS/$job" ]; then _FF_REASON="its job $job has no record on disk"; return 0; fi
  ( cmd_wait "$job" --for 0 ) >/dev/null 2>&1; rc=$?
  st="$(_reconcile_status "$job" 2>/dev/null || echo unknown)"
  r="$(head -1 "$OSRC_JOBS/$job/reason" 2>/dev/null | tr -d '\r' | cut -c1-160)"
  case "$rc" in
    0)   _FF_OUT=ok ;;
    124) _FF_OUT=live ;;
    3)   _FF_OUT=blocked; _FF_REASON="its worker is $st and needs input${r:+ ($r)}" ;;
    *)   _FF_OUT=failed; _FF_REASON="job $job ended $st${r:+ ($r)}" ;;
  esac
}

# _ff_fail_or_retry <plan> <tid> <reason>: retry while attempts remain, putting the reason into the
# task prompt so the next brief says why the last try failed; otherwise fail and call the captain.
# Attempts = max(.attempts, number of jobs launched), so it works whichever side counts them.
_ff_fail_or_retry() {
  local plan="$1" tid="$2" reason="$3" t n retries
  t="$(_task_get "$plan" "$tid")" || return 1
  n="$(printf '%s' "$t" | jq -r '[(.attempts // 0), ((.jobs // []) | length)] | max')"
  retries="$(printf '%s' "$t" | jq -r '.retries // 0')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac; case "$retries" in ''|*[!0-9]*) retries=0 ;; esac
  if [ "$n" -le "$retries" ]; then
    # Same reset as `task retry`; .result carries the reason, which the next brief prints under
    # "Earlier attempt", so the next worker knows what went wrong.
    FACTORY_EVENT_NOTE="retry: $reason" _task_update "$plan" "$tid" \
      '.state = "todo" | .job = "" | .worktree = "" | .branch = "" | .base_sha = "" | .head_sha = "" | .evidence = ""
       | .result = ("previous attempt failed because " + $r)' \
      --arg r "$reason" >/dev/null || return 1
    _ff_event "$plan" "$tid" retry "attempt $n failed: $reason"
    printf '  %s: retrying (attempt %s failed: %s)\n' "$tid" "$n" "$reason"
  else
    FACTORY_EVENT_NOTE="failed: $reason" _task_update "$plan" "$tid" \
      '.state = "failed" | .result = ("failed after " + $n + " attempt(s): " + $r)
       | .hold = ((.hold // {}) + {reason: ("failed after " + $n + " attempt(s): " + $r + ". Retry with `task retry`, or cancel it.")})' \
      --arg r "$reason" --arg n "$n" >/dev/null || return 1
    printf '  %s: failed for good after %s attempt(s): %s\n' "$tid" "$n" "$reason"
  fi
}

_ff_hold() {   # <plan> <tid> <reason>   (the task store sends the wake)
  local plan="$1" tid="$2" reason="$3"
  FACTORY_EVENT_NOTE="$reason" _task_update "$plan" "$tid" '.state = "held" | .hold_after_deps = false | .hold = ((.hold // {}) + {reason: $r})' \
    --arg r "$reason" >/dev/null || return 1
  printf '  %s: held for the captain: %s\n' "$tid" "$reason"
}

# _ff_task_output <plan> <tid> -> the worker's final text (report copy first, then the job's last.txt).
_ff_task_output() {
  local plan="$1" tid="$2" pd job
  pd="$(_plan_dir "$plan")"
  if [ -s "$pd/tasks/$tid/report.md" ]; then cat "$pd/tasks/$tid/report.md"; return 0; fi
  job="$(_task_get "$plan" "$tid" | jq -r '.job // ""')"
  [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ] && cat "$OSRC_JOBS/$job/last.txt"
  return 0
}

_ff_is_land_target() {   # <tasks-json> <tid> -> 0 when some flow land stage owns landing this task
  printf '%s' "$1" | jq -e --arg t "$2" 'any(.[]; (.land_target // "") == $t)' >/dev/null 2>&1
}

# _ff_verify <plan> <tid> <tasks-json>: job succeeded -> the done contract decides.
_ff_verify() {
  local plan="$1" tid="$2" tasks="$3" out rc t shape ev pd verdict_line
  out="$( _factory_done_check "$plan" "$tid" 2>&1 )"; rc=$?
  out="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/ $//' | cut -c1-200)"
  if [ "$rc" -ne 0 ]; then
    _ff_fail_or_retry "$plan" "$tid" "the done check said no: ${out:-no reason given}"
    return 0
  fi
  t="$(_task_get "$plan" "$tid")" || return 1
  shape="$(printf '%s' "$t" | jq -r '.shape // "scout"')"
  pd="$(_plan_dir "$plan")"; ev=""; [ -f "$pd/tasks/$tid/evidence.json" ] && ev="$pd/tasks/$tid/evidence.json"
  if [ "$(printf '%s' "$t" | jq -r '.require_verdict // false')" = "true" ]; then
    verdict_line="$(_ff_task_output "$plan" "$tid" | grep -E '^[[:space:]*#>-]*VERDICT:' | tail -1 | sed 's/^[[:space:]*#>-]*//' | cut -c1-160)"
    case "$verdict_line" in
      'VERDICT: PASS'*|'VERDICT:PASS'*) ;;
      *) _task_update "$plan" "$tid" '.evidence = $e | .result = (if $v == "" then "no verdict" else $v end)' \
           --arg e "$ev" --arg v "$verdict_line" >/dev/null
         _ff_hold "$plan" "$tid" "the reviewer did not pass it (${verdict_line:-no VERDICT line}); read its report, then \`task done\` to accept or retry the work it reviewed"
         return 0 ;;
    esac
  fi
  declare -F _task_finish_from_output >/dev/null 2>&1 && _task_finish_from_output "$plan" "$tid"
  FACTORY_EVENT_NOTE="$out" _task_update "$plan" "$tid" '.state = "done" | (if $e != "" then .evidence = $e else . end)
      | .result = (if (.result // "") == "" or (.result | startswith("previous attempt failed")) then $o else .result end)' \
    --arg e "$ev" --arg o "$out" >/dev/null || return 1
  printf '  %s: done\n' "$tid"
  if [ "$_FF_AUTO_LAND" = 1 ] && [ "$shape" = ship ] && ! _ff_is_land_target "$tasks" "$tid"; then
    _ff_land "$plan" "$tid" "$tid"
  fi
}

# _ff_land <plan> <target-tid> <owner-tid>: run the merge gate for target; the outcome is recorded
# on owner (the target itself under --auto-land, or the flow's land stage).
_ff_land() {
  local plan="$1" target="$2" owner="$3" out rc st
  if ! declare -F cmd_land >/dev/null 2>&1; then
    _ff_hold "$plan" "$owner" "landing is not available in this build; land $target by hand"
    return 0
  fi
  out="$( cmd_land "$target" --plan "$plan" 2>&1 )"; rc=$?
  out="$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-200)"
  if [ "$rc" -eq 0 ]; then
    [ "$owner" != "$target" ] && _task_update "$plan" "$owner" '.state = "done" | .result = ("landed " + $t + ": " + $o)' \
      --arg t "$target" --arg o "$out" >/dev/null
    printf '  %s: landed\n' "$target"
    return 0
  fi
  st="$(_task_get "$plan" "$owner" | jq -r '.state')"
  if [ "$st" != failed ]; then
    _task_update "$plan" "$owner" '.state = "failed" | .result = ("landing failed: " + $o)
      | .hold = ((.hold // {}) + {reason: ("landing " + $t + " failed: " + $o)})' --arg o "$out" --arg t "$target" >/dev/null
  fi
  printf '  %s: landing %s failed: %s\n' "$owner" "$target" "$out"
}

_ff_reconcile() {   # <plan>
  local plan="$1" tasks tid st job
  tasks="$(_task_list "$plan")" || return 1
  for tid in $(printf '%s' "$tasks" | jq -r '.[] | select(.state == "running" or .state == "verifying") | .id'); do
    st="$(_task_get "$plan" "$tid" | jq -r '.state')"
    case "$st" in
      running)
        job="$(_task_get "$plan" "$tid" | jq -r '.job // ""')"
        _ff_job_outcome "$job"
        case "$_FF_OUT" in
          live)    ;;
          ok)      _task_update "$plan" "$tid" '.state = "verifying"' >/dev/null && _ff_verify "$plan" "$tid" "$tasks" ;;
          blocked) _ff_hold "$plan" "$tid" "$_FF_REASON" ;;
          *)       _ff_fail_or_retry "$plan" "$tid" "$_FF_REASON" ;;
        esac ;;
      verifying) _ff_verify "$plan" "$tid" "$tasks" ;;   # a previous run stopped mid-check
    esac
  done
}

# ---------------------------------------------------------------- scheduler: dispatch

_ff_dispatch() {   # <plan> <max-parallel>
  local plan="$1" max="$2" tasks active tid t out rc st answer target
  tasks="$(_task_list "$plan")" || return 1
  active="$(printf '%s' "$tasks" | jq '[.[] | select(.state == "running" or .state == "verifying")] | length')"
  for tid in $(_task_ready "$plan"); do
    t="$(_task_get "$plan" "$tid")" || continue
    [ "$(printf '%s' "$t" | jq -r '.state')" = todo ] || continue
    if [ "$(printf '%s' "$t" | jq -r '.hold_after_deps // false')" = "true" ]; then
      _ff_hold "$plan" "$tid" "captain's decision: $(printf '%s' "$t" | jq -r '.title // ""'); answer with: task release $tid --answer \"<your decision>\""
      continue
    fi
    target="$(printf '%s' "$t" | jq -r '.land_target // ""')"
    if [ -n "$target" ]; then
      _task_update "$plan" "$tid" '.state = "running"' >/dev/null || continue
      _ff_land "$plan" "$target" "$tid"
      continue
    fi
    answer="$(printf '%s' "$t" | jq -r '.hold.answer // ""')"
    if [ "$(printf '%s' "$t" | jq -r '.gate // false')" = "true" ]; then
      # A released decision gate: nothing to run, the captain's answer is the result.
      _task_update "$plan" "$tid" '.state = "done" | .result = (if $a == "" then "approved" else $a end)' --arg a "$answer" >/dev/null
      printf '  %s: decided by the captain: %s\n' "$tid" "${answer:-approved}"
      continue
    fi
    [ "$active" -lt "$max" ] || continue
    out="$( _task_dispatch "$plan" "$tid" 2>&1 )"; rc=$?
    if [ "$rc" -eq 0 ]; then
      active=$((active + 1))
      printf '  %s: started job %s\n' "$tid" "$(printf '%s' "$out" | tail -1)"
    else
      out="$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | sed 's/^ERROR: //' | cut -c1-200)"
      # A launch failure is already recorded by _task_dispatch (task failed with the reason, wake
      # sent). A refusal that left the task waiting (lock busy, raced) is retried next pass.
      st="$(_task_get "$plan" "$tid" | jq -r '.state')"
      if [ "$st" = failed ]; then printf '  %s: could not start: %s\n' "$tid" "$out"
      else printf '  %s: not started this pass (%s); will try again\n' "$tid" "$out"; fi
    fi
  done
}

# ---------------------------------------------------------------- summary + stop reasons

# All three read _task_view (the task store's derived ready/blocked state + blocked_by), so the
# scheduler and `task ls` never disagree about what is ready or what waits on what.

# _ff_counts <plan> -> "total done canceled failed held running ready blocked todo" (one line)
_ff_counts() {
  _task_view "$1" | jq -r '
    def n(f): [.[] | select(f)] | length;
    [length, n(.state == "done"), n(.state == "canceled"), n(.state == "failed"), n(.state == "held"),
     n(.state == "running" or .state == "verifying"), n(.derived == "ready"), n(.derived == "blocked"),
     n(.state == "todo")] | map(tostring) | join(" ")'
}

# _ff_summary <plan> [tick]: the four buckets on one compact line.
_ff_summary() {
  _task_view "$1" | jq -r --arg plan "$1" --arg tick "${2:-}" '
    def ids(f): [.[] | select(f) | .id] | (if length > 6 then (.[0:6] + ["+\(length - 6)"]) else . end) | join(",");
    def paren(s): if s == "" then "" else " (" + s + ")" end;
    "[\($plan)\(if $tick == "" then "" else " tick \($tick)" end)] "
    + "Captain'"'"'s Call: \([.[] | select(.state == "held" or .state == "failed")] | length)" + paren(ids(.state == "held" or .state == "failed"))
    + " | Landed/Done: \([.[] | select(.state == "done")] | length)"
    + " | Underway: \([.[] | select(.state == "running" or .state == "verifying")] | length)" + paren(ids(.state == "running" or .state == "verifying"))
    + " | Next: \([.[] | select(.derived == "ready")] | length) ready" + paren(ids(.derived == "ready"))
    + ", \([.[] | select(.derived == "blocked")] | length) waiting"'
}

# _ff_why_stuck <plan>: one plain line naming what is held, failed, or blocked and on what.
_ff_why_stuck() {
  _task_view "$1" | jq -r '
    ([.[] | select(.state == "held") | .id]) as $held
    | ([.[] | select(.state == "failed") | .id]) as $failed
    | ([.[] | select(.derived == "blocked")
        | "\(.id) waits on \((.blocked_by // []) | map(.id + " (" + .state + ")") | join(", "))"]) as $blocked
    | [ (if ($held | length) > 0 then "held: " + ($held | join(", ")) else empty end),
        (if ($failed | length) > 0 then "failed: " + ($failed | join(", ")) else empty end),
        (if ($blocked | length) > 0 then "blocked: " + ($blocked | join("; ")) else empty end) ]
    | join(" · ")'
}

# ---------------------------------------------------------------- `plan run`

_FF_AUTO_LAND=0
cmd_plan_run() {
  local plan="" max=3 once=0 interval=30 maxmin=240 a pd t0 tick=0 c total done_n canceled failed held running ready todo why elapsed sl rc
  _FF_AUTO_LAND=0
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --max-parallel) max="${2:-}"; shift 2 || true ;;
      --max-parallel=*) max="${a#*=}"; shift ;;
      --interval) interval="${2:-}"; shift 2 || true ;;
      --interval=*) interval="${a#*=}"; shift ;;
      --max-minutes) maxmin="${2:-}"; shift 2 || true ;;
      --max-minutes=*) maxmin="${a#*=}"; shift ;;
      --once) once=1; shift ;;
      --auto-land) _FF_AUTO_LAND=1; shift ;;
      --plan) plan="${2:-}"; shift 2 || true ;;
      -h|--help) _ff_plan_run_usage; return 0 ;;
      -*) die "plan run: unknown option '$a' ($(_ff_plan_run_usage | head -1))" ;;
      *) [ -z "$plan" ] || die "plan run takes one plan name (got '$plan' and '$a')"; plan="$a"; shift ;;
    esac
  done
  case "$max" in ''|*[!0-9]*|0) die "plan run --max-parallel needs a whole number of 1 or more" ;; esac
  case "$interval" in ''|*[!0-9]*|0) die "plan run --interval needs a whole number of seconds (1 or more)" ;; esac
  case "$maxmin" in ''|*[!0-9]*|0) die "plan run --max-minutes needs a whole number of minutes (1 or more)" ;; esac
  _ff_need_jq
  _ff_need_fns _plan_dir _plan_resolve _task_get _task_update _task_list _task_view _task_ready _task_dispatch _factory_done_check
  plan="$(_plan_resolve ${plan:+"$plan"})" || return 1
  [ -n "$plan" ] || die "no plan given and no current plan; name one: plan run <plan>"
  pd="$(_plan_dir "$plan")" || return 1
  [ -d "$pd" ] || die "no plan named '$plan' (see: plan ls)"

  if ! _ff_lock_acquire "$pd/run.lock"; then
    echo "another 'plan run' is already driving $plan (pid $_FF_LOCK_HOLDER); not starting a second one so nothing runs twice." >&2
    return 1
  fi
  # Released on every return path and on Ctrl-C/TERM. Deliberately NOT chained onto the EXIT trap:
  # inside a subshell that would also fire a sourcing caller's own EXIT handler. If the process dies
  # hard (kill -9, die), the lock's owner pid is dead and the next `plan run` reclaims it.
  trap '_ff_lock_release; exit 130' INT; trap '_ff_lock_release; exit 143' TERM

  t0=$(date +%s)
  while :; do
    tick=$((tick + 1))
    _ff_reconcile "$plan"
    _ff_dispatch "$plan" "$max"
    _ff_summary "$plan" "$tick"
    c="$(_ff_counts "$plan")" || { _ff_lock_release; die "could not read the tasks of $plan"; }
    set -- $c; total=$1 done_n=$2 canceled=$3 failed=$4 held=$5 running=$6 ready=$7 todo=$9
    rc=""
    if [ "$total" -eq 0 ]; then
      echo "stopped: $plan has no tasks yet; add some with 'task add' or 'flow run'."; rc=0
    elif [ "$running" -eq 0 ] && [ "$ready" -eq 0 ]; then
      if [ "$failed" -eq 0 ] && [ "$held" -eq 0 ] && [ "$todo" -eq 0 ]; then
        if [ "$canceled" -gt 0 ]; then echo "stopped: $plan is finished ($done_n done, $canceled canceled)."
        else echo "stopped: $plan is finished ($done_n done)."; fi
        _ff_wake_finished "$plan" "$done_n"
        rc=0
      else
        why="$(_ff_why_stuck "$plan")"
        echo "stopped: $plan needs the captain, nothing else can move. ${why}"
        rc=3
      fi
    elif [ "$once" = 1 ]; then
      echo "one tick done: $running underway, $ready ready. Run 'plan run $plan' to keep driving it."; rc=124
    else
      elapsed=$(( $(date +%s) - t0 ))
      if [ "$elapsed" -ge $((maxmin * 60)) ]; then
        echo "stopped: time cap of $maxmin minutes reached with $running still underway (their jobs keep running). Run 'plan run $plan' again to pick up where this left off."
        rc=2
      fi
    fi
    if [ -n "$rc" ]; then
      _ff_lock_release; trap - INT TERM
      return "$rc"
    fi
    sl="$interval"; elapsed=$(( $(date +%s) - t0 ))
    [ $((maxmin * 60 - elapsed)) -lt "$sl" ] && sl=$((maxmin * 60 - elapsed))
    [ "$sl" -lt 1 ] && sl=1
    sleep "$sl"
  done
}

_ff_wake_finished() {   # <plan> <done-count>: one wake per distinct finished state, not one per tick
  local plan="$1" n="$2" pd sig
  pd="$(_plan_dir "$plan")"
  sig="$(_task_list "$plan" | jq -r '[.[] | .id + ":" + .state] | sort | join(",")' | cksum | cut -d' ' -f1)"
  [ "$(cat "$pd/.finished-woken" 2>/dev/null)" = "$sig" ] && return 0
  _ff_wake "$plan" "-" finished "plan $plan finished: $n task(s) done"
  printf '%s\n' "$sig" > "$pd/.finished-woken.$$" 2>/dev/null && mv -f "$pd/.finished-woken.$$" "$pd/.finished-woken" 2>/dev/null
  return 0
}

_ff_plan_run_usage() {
  cat <<'EOF'
usage: plan run [plan] [--max-parallel N] [--once] [--interval S] [--auto-land] [--max-minutes M]
  Drives a plan: checks running work, finishes or retries it, starts ready tasks (up to N at once, default 3).
  --once         one pass, then exit (for the heartbeat or an orchestrator turn)
  --interval S   seconds between passes (default 30)
  --auto-land    land each finished build task through the merge gate as soon as it is done
  --max-minutes  stop driving after M minutes (default 240); running jobs keep going
  exit: 0 all done | 3 needs the captain (held or failed work) | 2 time cap | 124 --once with work still underway | 1 error
EOF
}

# ---------------------------------------------------------------- one line per active plan (bearings/rundown)
_factory_plans_digest() {
  local root="$OSRC_HOME/plans" d plan c
  [ -d "$root" ] && have jq || return 0
  declare -F _task_view >/dev/null 2>&1 || return 0
  for d in "$root"/*/; do
    [ -f "$d/plan.json" ] || continue
    plan="$(basename "$d")"
    c="$(_ff_counts "$plan" 2>/dev/null)" || continue
    set -- $c
    [ "${1:-0}" -gt 0 ] || continue
    [ $(( $4 + $5 + $6 + $9 )) -gt 0 ] || continue   # skip finished plans
    printf 'plan %s: %s need you · %s done · %s underway · %s next (%s ready)\n' "$plan" "$(( $4 + $5 ))" "$2" "$6" "$9" "$7"
  done
  return 0
}

# ================================================================ flows

_ff_flow_dirs() {   # user flows first so they override built-ins by name
  printf '%s\n' "$OSRC_HOME/flows"
  printf '%s\n' "${OSRC_FLOWS_BUILTIN_DIR:-$_FF_DIR/../references/flows}"
}

_ff_flow_path() {   # <name> -> path of the winning flow file (rc1 if none)
  local name="$1" d
  _ff_name_ok "$name" || return 1
  while IFS= read -r d; do
    [ -f "$d/$name.json" ] && { printf '%s\n' "$d/$name.json"; return 0; }
  done <<EOF
$(_ff_flow_dirs)
EOF
  return 1
}

# _ff_flow_load <name> -> validated flow JSON (dies with a plain reason when it is malformed)
_ff_flow_load() {
  local name="$1" path err
  _ff_name_ok "$name" || die "flow names use letters, digits, dot, dash and underscore only (got '$name')"
  path="$(_ff_flow_path "$name")" || die "no flow named '$name' (see: flow ls)"
  jq -e . "$path" >/dev/null 2>&1 || die "flow file $path is not valid JSON"
  err="$(jq -r '
    def sid: "^[A-Za-z0-9_-]+$";
    if (.stages | type) != "array" or (.stages | length) == 0 then "it has no stages"
    elif ((.vars // {}) | type) != "object" then "vars must be an object"
    else
      (.stages | map(.id)) as $ids
      | ([.stages | to_entries[] | .key as $k | .value as $s
          | if ($s.id | type) != "string" or ($s.id | test(sid) | not) then "stage \($k + 1) has a missing or bad id"
            elif ([$ids[] | select(. == $s.id)] | length) > 1 then "stage id \($s.id) is used twice"
            elif ($s.land // "") == "" and (($s.shape // "scout") | IN("scout","ship") | not) then "stage \($s.id): shape must be scout or ship"
            elif ($s.land // "") == "" and (($s.verb // "run") | IN("run","research","edit","yolo") | not) then "stage \($s.id): verb must be run, research, edit or yolo"
            elif ([($s.deps // [])[] | . as $d | select(($ids[0:$k] | index($d)) == null)] | length) > 0
              then "stage \($s.id) depends on \([($s.deps // [])[] | . as $d | select(($ids[0:$k] | index($d)) == null)] | join(", ")), which is not an earlier stage"
            elif ($s.land // "") != "" and (($ids[0:$k] | index($s.land)) == null) then "stage \($s.id) lands \($s.land), which is not an earlier stage"
            elif ($s.land // "") == "" and ($s.hold // false) != true and (($s.prompt // "") == "") then "stage \($s.id) has no prompt"
            else empty end] | first) // ""
    end' "$path")"
  [ -z "$err" ] || die "flow '$name' ($path) is broken: $err"
  jq -c --arg src "$path" '. + {_source: $src}' "$path"
}

# _ff_flow_vars_used <flow-json> -> newline list of {{var}} names used in the stages
_ff_flow_vars_used() {
  printf '%s' "$1" | jq -r '[.stages[] | (.title, .prompt, .check, .repeat, .model, (.fallback // [])[], (.models // [])[])
     | select(type == "string") | [match("\\{\\{([A-Za-z_][A-Za-z0-9_]*)\\}\\}"; "g") | .captures[0].string][]] | unique[]'
}

# _ff_pick_model <candidate>... -> first one not on the exclude list (empty when all are excluded)
_ff_pick_model() {
  local m
  for m in "$@"; do
    [ -n "$m" ] || continue
    if declare -F _model_excluded >/dev/null 2>&1 && _model_excluded "$m" >/dev/null 2>&1; then continue; fi
    printf '%s\n' "$m"; return 0
  done
  return 0
}

# _ff_subst <json-string-value> <vars-json>: single-pass {{var}} substitution done inside jq. Values
# are inserted literally (never evaluated, never re-scanned), so quotes, $(...) and backticks in a
# value stay plain text. Unknown placeholders are left in place (caught earlier by validation).
_FF_SUBST_JQ='def sub($v): if type == "string" then gsub("\\{\\{(?<k>[A-Za-z_][A-Za-z0-9_]*)\\}\\}"; ($v[.k] // ("{{" + .k + "}}"))) else . end;'

# _ff_flow_expand <flow-json> <vars-json> -> JSON array of concrete stages (repeat expanded, vars
# substituted, models chosen against the exclude list). Each item keeps "sid" (stage id), "copy_of"
# (base stage id for repeated stages) and the original deps (stage ids).
_ff_flow_expand() {
  local flow="$1" vars="$2" n i k cnt base stage out="[]" model models
  n="$(printf '%s' "$flow" | jq '.stages | length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    stage="$(printf '%s' "$flow" | jq -c --argjson i "$i" '.stages[$i]')"
    cnt="$(printf '%s' "$stage" | jq -r --argjson v "$vars" "$_FF_SUBST_JQ"' (.repeat // "1") | tostring | sub($v)')"
    case "$cnt" in ''|*[!0-9]*) die "stage $(printf '%s' "$stage" | jq -r .id) repeats '$cnt' times; that must be a whole number (for example --var n=3)" ;; esac
    { [ "$cnt" -ge 1 ] && [ "$cnt" -le 10 ]; } || die "stage $(printf '%s' "$stage" | jq -r .id) repeats $cnt times; pick 1 to 10"
    k=1
    while [ "$k" -le "$cnt" ]; do
      # Per-copy vars add {{i}} (copy number) and {{n}} (copy count); flow vars win if they define them.
      base="$(printf '%s' "$stage" | jq -c --argjson v "$vars" --arg i "$k" --arg n "$cnt" "$_FF_SUBST_JQ"'
        ({i: $i, n: $n} + $v) as $vv
        | . as $s
        | {sid: (if ($s | has("repeat")) then $s.id + "-" + $i else $s.id end), copy_of: $s.id,
           title: (($s.title // $s.id) | sub($vv)), shape: ($s.shape // "scout"), verb: ($s.verb // "run"),
           prompt: (($s.prompt // "") | sub($vv)), check: (($s.check // "") | sub($vv)),
           deps: ($s.deps // []), hold: ($s.hold // false), land: ($s.land // ""), verdict: ($s.verdict // false),
           retries: ($s.retries // 1), deliver: ($s.deliver // (if ($s.shape // "scout") == "ship" then "branch" else "local" end)),
           provider: ($s.provider // ""),
           cands: ((if ($s.models // []) | length > 0
                    then ($s.models | length) as $L | [range(0; $L)] | map($s.models[(. + ($i | tonumber) - 1) % $L])
                    else [($s.model // "")] + ($s.fallback // []) end) | map(sub($vv)))}')"
      models="$(printf '%s' "$base" | jq -r '.cands[]')"
      # shellcheck disable=SC2086
      model="$(set -f; _ff_pick_model $models)"
      if [ -n "$models" ] && [ -z "$model" ] && [ "$(printf '%s' "$base" | jq -r '.land')" = "" ]; then
        echo "note: every model named for stage $(printf '%s' "$base" | jq -r .sid) is on your exclude list; the router will pick one." >&2
      fi
      out="$(printf '%s' "$out" | jq -c --argjson b "$base" --arg m "$model" '. + [($b | del(.cands) + {model: $m})]')"
      k=$((k + 1))
    done
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# _ff_parse_vars <flow-json> <JSON array of "k=v" strings> -> merged vars JSON (defaults applied);
# dies on a missing required var or an unknown one. Values stay data end to end (jq --arg), never eval'd.
_ff_parse_vars() {
  local flow="$1" kvs="$2" vars="{}" kv k v missing unknown used cnt i
  cnt="$(printf '%s' "$kvs" | jq 'length')"; i=0
  while [ "$i" -lt "$cnt" ]; do
    kv="$(printf '%s' "$kvs" | jq -r --argjson i "$i" '.[$i]')"; i=$((i + 1))
    case "$kv" in *=*) ;; *) die "--var needs name=value (got '$kv')" ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ''|[0-9]*|*[!A-Za-z0-9_]*) die "--var name '$k' must be letters, digits and underscore" ;; esac
    vars="$(printf '%s' "$vars" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}')"
  done
  unknown="$(printf '%s' "$flow" | jq -r --argjson v "$vars" '(.vars // {}) as $d | [$v | keys[] | . as $k | select(($d | has($k)) | not)] | join(", ")')"
  [ -z "$unknown" ] || die "flow $(printf '%s' "$flow" | jq -r .name) has no variable $unknown (it takes: $(printf '%s' "$flow" | jq -r '(.vars // {}) | keys | join(", ")'))"
  missing="$(printf '%s' "$flow" | jq -r --argjson v "$vars" '[(.vars // {}) | to_entries[] | select(.value == "required" and (($v[.key] // "") == "")) | .key] | join(", ")')"
  [ -z "$missing" ] || die "flow $(printf '%s' "$flow" | jq -r .name) needs $(printf '%s' "$missing" | sed 's/\([A-Za-z0-9_]*\)/--var \1=.../g')"
  vars="$(printf '%s' "$flow" | jq -c --argjson v "$vars" '
    reduce ((.vars // {}) | to_entries[]) as $e ({};
      . + {($e.key): (if ($e.value | type) == "object" then ($e.value.default // "" | tostring)
                      elif $e.value == "required" or $e.value == "optional" then ""
                      else ($e.value | tostring) end)}) + $v')"
  used="$(_ff_flow_vars_used "$flow")"
  for k in $used; do
    case "$k" in i|n) continue ;; esac
    printf '%s' "$vars" | jq -e --arg k "$k" 'has($k)' >/dev/null || die "flow $(printf '%s' "$flow" | jq -r .name) uses {{$k}} but does not declare it under vars"
  done
  printf '%s\n' "$vars"
}

# _ff_plan_ensure <plan> <goal> <repo-arg> <needs-repo 0|1>: create the plan if missing (data model
# exactly as the task store writes it), refuse a code-building flow without a git repo.
_ff_plan_ensure() {
  local plan="$1" goal="$2" repoarg="$3" needrepo="$4" pd repo="" base="" now tmp
  pd="$(_plan_dir "$plan")" || return 1
  if [ -f "$pd/plan.json" ]; then
    repo="$(jq -r '.repo // ""' "$pd/plan.json")"
    [ "$needrepo" = 0 ] || [ -n "$repo" ] || die "plan $plan has no git repo, and this flow builds code; use a plan made inside a repo, or pass --plan with a new name and --repo <path>"
    return 0
  fi
  if [ -n "$repoarg" ]; then
    repo="$(git -C "$repoarg" rev-parse --show-toplevel 2>/dev/null)" || die "--repo $repoarg is not inside a git repository"
  else
    repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  [ "$needrepo" = 0 ] || [ -n "$repo" ] || die "this flow builds code, so it needs a git repo; run it inside one or pass --repo <path>"
  [ -n "$repo" ] && base="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if declare -F _plan_cli_new >/dev/null 2>&1; then
    # The task store's own `plan new` (base-branch checks, events, private dirs). Made current only
    # when there is no current plan yet, so a flow never steals focus from the plan you are on.
    set -- "$plan" --goal "$goal"
    if [ -n "$repo" ]; then set -- "$@" --repo "$repo"; else set -- "$@" --no-repo; fi
    [ -s "$OSRC_HOME/plans/current" ] && set -- "$@" --no-use
    ( _plan_cli_new "$@" ) >/dev/null || die "could not create plan $plan"
    return 0
  fi
  now="$(_ff_now)"
  mkdir -p "$pd/tasks" || die "could not create the plan folder $pd"
  tmp="$pd/.plan.json.$$"
  jq -n --arg name "$plan" --arg goal "$goal" --arg repo "$repo" --arg base "$base" --arg now "$now" \
    '{schema:1,name:$name,goal:$goal,repo:$repo,base_branch:$base,created:$now,updated:$now}' > "$tmp" \
    && mv -f "$tmp" "$pd/plan.json" || die "could not write $pd/plan.json"
  [ -s "$OSRC_HOME/plans/current" ] || { printf '%s\n' "$plan" > "$OSRC_HOME/plans/current.$$" && mv -f "$OSRC_HOME/plans/current.$$" "$OSRC_HOME/plans/current"; }
  return 0
}

cmd_flow() {
  local sub="${1:-}"; shift || true
  _ff_need_jq
  case "$sub" in
    ls|list)   _ff_flow_ls ;;
    show)      [ -n "${1:-}" ] || die "usage: flow show <name>"; _ff_flow_show "$1" ;;
    run)       _ff_flow_run "$@" ;;
    ""|-h|--help|help)
      cat <<'EOF'
usage: flow ls | flow show <name> | flow run <name> [--plan p] [--var k=v ...] [--repo path] [--dry-run]
  A flow is a reusable recipe of tasks (scouts, builds, reviews, captain decisions). `flow run` turns
  it into tasks in a plan; then `plan run <plan>` drives them. Your own flows in ~/.outsourcerer/flows/
  (or $OSRC_HOME/flows/) override the built-in ones by name.
EOF
      ;;
    *) die "flow: unknown action '$sub' (use: flow ls | flow show <name> | flow run <name>)" ;;
  esac
}

_ff_flow_ls() {
  local d f name seen="" src
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      name="$(basename "$f" .json)"
      _ff_name_ok "$name" || continue
      case " $seen " in *" $name "*) continue ;; esac
      seen="$seen $name"
      src="built-in"; [ "$d" = "$OSRC_HOME/flows" ] && src="yours"
      printf '%-16s %-8s %s\n' "$name" "$src" "$(jq -r '.description // "" | gsub("[[:cntrl:]]"; " ") | .[0:110]' "$f" 2>/dev/null || echo '(unreadable)')"
    done
  done <<EOF
$(_ff_flow_dirs)
EOF
  [ -n "$seen" ] || echo "no flows found"
}

_ff_flow_show() {
  local flow
  flow="$(_ff_flow_load "$1")" || return 1
  printf '%s' "$flow" | jq -r '
    "\(.name): \(.description // "")",
    "from: \(._source)",
    "vars: " + ((.vars // {}) | to_entries | map(.key + (if .value == "required" then " (required)" elif .value == "optional" then " (optional)" elif (.value | type) == "object" then " (default " + (.value.default // "" | tostring) + ")" else " (default " + (.value | tostring) + ")" end)) | join(", ")),
    "stages:",
    (.stages[] | "  " + .id
       + (if (.land // "") != "" then "  lands " + .land
          else "  " + (.shape // "scout") + "/" + (.verb // "run")
               + (if (.models // []) | length > 0 then "  models " + (.models | join("|"))
                  elif (.model // "") != "" then "  model " + .model + (if (.fallback // []) | length > 0 then " (then " + (.fallback | join(", ")) + ")" else "" end)
                  else "" end) end)
       + (if (.repeat // null) != null then "  x" + (.repeat | tostring) else "" end)
       + (if (.deps // []) | length > 0 then "  after " + (.deps | join(",")) else "" end)
       + (if .hold == true then "  [captain decides]" else "" end)
       + (if .verdict == true then "  [must say VERDICT: PASS]" else "" end)
       + "  - " + (.title // ""))'
}

_ff_flow_run() {
  local name="" plan="" repo="" dry=0 a flow vars stages goal needrepo n i st sid tid map="" deps_json json model title rows="" copy land
  local kvs="[]"
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --plan) plan="${2:-}"; shift 2 || true ;;
      --plan=*) plan="${a#*=}"; shift ;;
      --repo) repo="${2:-}"; shift 2 || true ;;
      --repo=*) repo="${a#*=}"; shift ;;
      --var) [ "$#" -ge 2 ] || die "--var needs name=value"; kvs="$(printf '%s' "$kvs" | jq -c --arg kv "$2" '. + [$kv]')"; shift 2 ;;
      --var=*) kvs="$(printf '%s' "$kvs" | jq -c --arg kv "${a#--var=}" '. + [$kv]')"; shift ;;
      --dry-run) dry=1; shift ;;
      -*) die "flow run: unknown option '$a'" ;;
      *) [ -z "$name" ] || die "flow run takes one flow name (got '$name' and '$a')"; name="$a"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: flow run <name> [--plan p] [--var k=v ...] [--repo path]"
  _ff_need_fns _plan_dir _task_new
  flow="$(_ff_flow_load "$name")" || return 1
  vars="$(_ff_parse_vars "$flow" "$kvs")" || return 1
  [ -n "$vars" ] || return 1
  stages="$(_ff_flow_expand "$flow" "$vars")" || return 1
  goal="$(printf '%s' "$vars" | jq -r '.goal // ""')"
  [ -n "$goal" ] || goal="$(printf '%s' "$flow" | jq -r '.description // .name')"
  needrepo="$(printf '%s' "$stages" | jq -r 'if any(.[]; .shape == "ship" and .land == "") then 1 else 0 end')"
  if [ -z "$plan" ]; then plan="$name-$(date +%Y%m%d-%H%M%S)"; fi
  _ff_name_ok "$plan" || die "plan names use letters, digits, dot, dash and underscore only (got '$plan')"

  if [ "$dry" = 1 ]; then
    echo "flow $name would add to plan $plan:"
    printf '%s' "$stages" | jq -r '.[] | "  " + .sid + "  " + (if .land != "" then "lands " + .land else .shape + "/" + .verb + (if .model != "" then " on " + .model else "" end) end) + (if (.deps | length) > 0 then "  after " + (.deps | join(",")) else "" end) + (if .hold then "  [captain decides]" else "" end) + "  - " + .title'
    return 0
  fi
  _ff_plan_ensure "$plan" "$goal" "$repo" "$needrepo"

  n="$(printf '%s' "$stages" | jq 'length')"; i=0
  while [ "$i" -lt "$n" ]; do
    st="$(printf '%s' "$stages" | jq -c --argjson i "$i" '.[$i]')"
    sid="$(printf '%s' "$st" | jq -r .sid)"
    # Translate stage-id deps into tids. A dep on a repeated stage means every copy.
    deps_json="$(printf '%s' "$st" | jq -c --arg map "$map" '
      ($map | split("\n") | map(select(. != "") | split("=") | {stage: .[0], copy: .[1], tid: .[2]})) as $m
      | [.deps[] as $d | $m[] | select(.stage == $d or .copy == $d) | .tid] | unique')"
    land="$(printf '%s' "$st" | jq -r .land)"
    local ltid=""
    if [ -n "$land" ]; then
      ltid="$(printf '%s' "$map" | awk -F= -v s="$land" '$2 == s || $1 == s { print $3 }' | head -2)"
      [ "$(printf '%s\n' "$ltid" | grep -c .)" = 1 ] || die "stage $sid lands '$land', which must be exactly one task"
      deps_json="$(printf '%s' "$deps_json" | jq -c --arg t "$ltid" '(. + [$t]) | unique')"
    fi
    json="$(printf '%s' "$st" | jq -c --argjson deps "$deps_json" --arg flow "$name" --arg ltid "$ltid" --arg now "$(_ff_now)" '
      {schema:1, title:.title, shape:(if .land != "" then "scout" else .shape end), state:"todo", deps:$deps,
       prompt:(if .land != "" then "" else .prompt end), spec:"", check:.check,
       verb:(if .land != "" then "run" else .verb end), model:.model, provider:.provider,
       deliver:(if .land != "" then "local" else .deliver end), retries:.retries, attempts:0,
       job:"", jobs:[], worktree:"", branch:"", base_sha:"", head_sha:"",
       hold:{reason:"",until:"",answer:""}, result:"", evidence:"",
       flow:{name:$flow, stage:.sid}, created:$now, updated:$now,
       hold_after_deps:.hold, gate:(.hold and .prompt == "" and .land == ""), land_target:$ltid, require_verdict:.verdict}')"
    tid="$(_task_new "$plan" "$json")" || die "could not add stage $sid to plan $plan"
    copy="$(printf '%s' "$st" | jq -r .copy_of)"
    map="$map$sid=$copy=$tid
"
    model="$(printf '%s' "$st" | jq -r .model)"; title="$(printf '%s' "$st" | jq -r .title)"
    rows="$rows$(printf '  %-14s -> %-4s %s%s' "$sid" "$tid" "${model:+[$model] }" "$title")
"
    i=$((i + 1))
  done
  echo "flow $name added $n task(s) to plan $plan:"
  printf '%s' "$rows"
  echo "next: $0 plan run $plan"
}
