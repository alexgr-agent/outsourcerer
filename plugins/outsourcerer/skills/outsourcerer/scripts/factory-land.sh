# shellcheck shell=bash
# factory-land.sh -- Track C of the 0.14 "factory": the DONE CONTRACT and the MERGE GATE (`land`).
# Sourced by outsourcerer.sh (never run directly). bash 3.2 safe, set -u safe.
#
# Reuses, never reinvents: _crew_check / _loop_check (bounded check runner), _check_signature,
# _crew_worktree_clean (tracked-only cleanliness), OSRC_SECRET_VALUE_ERE (the _crew_scan_staged
# patterns), _mkdir_claim + _pid_start_identity (house lock pattern), _wake_append, _new_job_id.
# Task store calls (Track B): _plan_dir, _plan_resolve, _task_get, _task_update, _task_event.
#
# Worker worktrees are NEVER removed here (that stays with `cleanup`). The only worktree this file
# creates is the throwaway integration worktree, and a trap removes it on every exit path.

_factory_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _factory_write_json <path> <json> -> atomic write (tmp + mv).
_factory_write_json() {
  local p="$1" tmp
  tmp="$1.tmp.$$.${RANDOM:-0}"
  [ -L "$p" ] && { echo "refusing to write through a symlink: $p" >&2; return 1; }
  if printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$p" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null; return 1
}

# _factory_job_status <job-id> -> the raw status word ("" when the job dir is missing).
_factory_job_status() {
  [ -n "${1:-}" ] || return 0
  case "$1" in */*|*..*) return 0 ;; esac
  cat "$OSRC_JOBS/$1/status" 2>/dev/null | head -1
}

# _factory_job_ok <job-id> -> rc0 when the job ended in terminal success (done, or done? = exited 0
# without the marker, which the contract counts as success; the check is what proves the work).
_factory_job_ok() {
  case "$(_factory_job_status "${1:-}")" in done|'done?') return 0 ;; esac
  return 1
}

# _factory_scan_range <dir> <base> <head> -> rc0 = a live secret is in the base..head diff (block),
# rc1 = clean, rc2 = the diff could not be read (callers fail closed). Same hardening as
# _crew_scan_staged: --text/--no-ext-diff/--no-textconv defeat a planted .gitattributes, and the diff
# is captured BEFORE grep so a big diff can't SIGPIPE git into a false "clean".
_factory_scan_range() {
  local _sd
  _sd="$(git -C "$1" diff --text --no-ext-diff --no-textconv "$2" "$3" 2>/dev/null)" || return 2
  grep -Eq "$OSRC_SECRET_VALUE_ERE" <<<"$_sd" && return 0
  return 1
}

# _factory_check_run <dir> <check> <outfile> -> runs the check (bounded) and fills _FG_CHECK_RC,
# _FG_SIG (cksum of the normalized signature) and _FG_TAIL (last lines, capped).
_factory_check_run() {
  local rc=0
  _crew_check "$1" "$2" "$3"; rc=$?
  _FG_CHECK_RC="$rc"
  _FG_SIG="$(_check_signature < "$3" 2>/dev/null | cksum | awk '{print $1}')"
  _FG_TAIL="$(tail -n 20 "$3" 2>/dev/null | cut -c1-300 | head -c 4000)"
  return "$rc"
}

_factory_gate_reset() {
  _FG_BASE=""; _FG_HEAD=""; _FG_BRANCH=""; _FG_AHEAD=0; _FG_CHECK=""; _FG_CHECK_RC=""
  _FG_SIG=""; _FG_TAIL=""; _FG_SECRET="not_run"; _FG_REASON=""
}

# _factory_gate_ship <worktree> <base_sha> <job-id> <check> <outdir>
# The ship rules of the done contract, in cheapest-first order. rc0 pass / rc1 fail; the reason is in
# _FG_REASON (one plain line, says what to do next). Fills _FG_* for the evidence record.
_factory_gate_ship() {
  local wt="$1" base="$2" job="$3" check="$4" outdir="$5" st cont dirtyf rc
  _FG_BASE="$base"; _FG_CHECK="$check"
  if [ -z "$job" ]; then _FG_REASON="no worker job is on record for this work yet; start it first"; return 1; fi
  if ! _factory_job_ok "$job"; then
    st="$(_factory_job_status "$job")"
    _FG_REASON="worker job $job has not finished successfully (status: ${st:-missing}); wait for it or retry"
    return 1
  fi
  if [ -z "$wt" ]; then _FG_REASON="no worktree is on record (ship work must run in its own worktree)"; return 1; fi
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _FG_REASON="the worktree $wt is missing or is not a git checkout"; return 1
  fi
  _FG_HEAD="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  _FG_BRANCH="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$base" ] || ! git -C "$wt" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
    _FG_REASON="no usable base commit is on record, so new commits can't be counted"; return 1
  fi
  _FG_BASE="$(git -C "$wt" rev-parse "$base^{commit}")"
  _FG_AHEAD="$(git -C "$wt" rev-list --count "$_FG_BASE..$_FG_HEAD" 2>/dev/null)"; _FG_AHEAD="${_FG_AHEAD:-0}"
  if [ "$_FG_AHEAD" -lt 1 ] 2>/dev/null; then
    _FG_REASON="the worker made no commits beyond the base ${_FG_BASE:0:12}; there is nothing to land"; return 1
  fi
  if ! _crew_worktree_clean "$wt"; then
    dirtyf="$(git -C "$wt" status --porcelain -uno 2>/dev/null | head -1 | cut -c4-)"
    _FG_REASON="the worktree has uncommitted changes to tracked files (${dirtyf:-?}); commit or discard them in $wt, then check again"
    return 1
  fi
  # Reachable from a NAMED branch (refs are shared by every worktree of the repo), not only a detached HEAD.
  cont="$(git -C "$wt" for-each-ref --contains "$_FG_HEAD" --format='%(refname:short)' refs/heads/ 2>/dev/null)"
  if [ -z "$cont" ]; then
    _FG_REASON="the latest commit ${_FG_HEAD:0:12} is not on any branch (detached HEAD); put it on a branch, then check again"
    return 1
  fi
  [ -n "$_FG_BRANCH" ] || _FG_BRANCH="$(printf '%s\n' "$cont" | head -1)"
  _factory_scan_range "$wt" "$_FG_BASE" "$_FG_HEAD"; rc=$?
  case "$rc" in
    0) _FG_SECRET="blocked"
       _FG_REASON="the changes contain what looks like a live secret (API key, token or private key); remove it from the branch history, then check again"
       return 1 ;;
    2) _FG_SECRET="blocked"
       _FG_REASON="could not read the diff to scan it for secrets; refusing to pass it unscanned"
       return 1 ;;
  esac
  _FG_SECRET="clean"
  if [ -n "$check" ]; then
    mkdir -p "$outdir" 2>/dev/null
    _factory_check_run "$wt" "$check" "$outdir/check.out"; rc=$?
    case "$rc" in
      0) ;;
      124) _FG_REASON="the check timed out in the worktree: $check"; return 1 ;;
      125) _FG_REASON="the check could not be started in the worktree: $check"; return 1 ;;
      *)   _FG_REASON="the check failed in the worktree (exit $rc): $check"; return 1 ;;
    esac
  fi
  local cmsg="no check set"; [ -n "$check" ] && cmsg="check passed"
  _FG_REASON="$_FG_AHEAD new commit(s) on $_FG_BRANCH, $cmsg, no secrets found"
  return 0
}

# _factory_evidence_json <task-or-job> <shape> <job> <verdict> <reason> -> evidence JSON from _FG_*.
_factory_evidence_json() {
  jq -cn --arg task "$1" --arg shape "$2" --arg job "$3" --arg verdict "$4" --arg reason "$5" \
    --arg base "${_FG_BASE:-}" --arg head "${_FG_HEAD:-}" --arg cmd "${_FG_CHECK:-}" \
    --arg rc "${_FG_CHECK_RC:-}" --arg sig "${_FG_SIG:-}" --arg tail "${_FG_TAIL:-}" \
    --arg sec "${_FG_SECRET:-not_run}" --arg ts "$(_factory_now)" \
    '{task:$task,shape:$shape,job:$job,base_sha:$base,head_sha:$head,
      check:{cmd:$cmd,rc:(if $rc=="" then null else ($rc|tonumber) end),signature:$sig,tail:$tail},
      secret_scan:$sec,verdict:$verdict,reason:$reason,ts:$ts}'
}

# _factory_done_check <plan> <tid> [check-override]
# The done contract. rc0 = done, rc1 = not done. Writes tasks/<tid>/evidence.json, records its path
# (and head_sha for ship) on the task, and prints ONE plain line: "<tid> done: ..." / "<tid> not done: ...".
# The optional 3rd arg replaces the task's check (used by `land --check`). It updates the task via
# _task_update, so do NOT call it while holding the plan lock.
_factory_done_check() {
  local plan="${1:-}" tid="${2:-}" ovr_set=0 ovr=""
  [ $# -ge 3 ] && { ovr_set=1; ovr="$3"; }
  have jq || die "the factory needs jq; install it (brew install jq / apt install jq) and try again"
  [ -n "$plan" ] && [ -n "$tid" ] || { echo "usage: _factory_done_check <plan> <tid>"; return 1; }
  local tj; tj="$(_task_get "$plan" "$tid" 2>/dev/null)" || { echo "$tid not done: there is no task $tid in plan $plan"; return 1; }
  local pd tdir ev shape job check wt base wj verdict reason rc=1 ej
  pd="$(_plan_dir "$plan")"; tdir="$pd/tasks/$tid"; mkdir -p "$tdir" 2>/dev/null; ev="$tdir/evidence.json"
  shape="$(jq -r '.shape // "ship"' <<<"$tj")"
  job="$(jq -r '.job // ""' <<<"$tj")"
  check="$(jq -r '.check // ""' <<<"$tj")"; [ "$ovr_set" = 1 ] && check="$ovr"
  wt="$(jq -r '.worktree // ""' <<<"$tj")"; base="$(jq -r '.base_sha // ""' <<<"$tj")"
  # Fall back to the job's worktree receipt for anything the task record is missing.
  if [ -n "$job" ] && { [ -z "$wt" ] || [ -z "$base" ]; }; then
    wj="$OSRC_JOBS/$job/worktree.json"
    if [ -f "$wj" ]; then
      [ -n "$wt" ] || wt="$(jq -r '.path // ""' "$wj" 2>/dev/null)"
      [ -n "$base" ] || base="$(jq -r '.base_sha // ""' "$wj" 2>/dev/null)"
    fi
  fi
  _factory_gate_reset
  if [ "$shape" = "scout" ]; then
    local res="" src=""
    if [ -z "$job" ]; then reason="no worker job is on record for this task yet; start it first"
    elif ! _factory_job_ok "$job"; then
      reason="worker job $job has not finished successfully (status: $(_factory_job_status "$job" | grep . || echo missing)); wait for it or retry"
    else
      if [ -s "$OSRC_JOBS/$job/last.txt" ]; then src="$OSRC_JOBS/$job/last.txt"
      elif [ -s "$OSRC_JOBS/$job/out.log" ]; then src="$OSRC_JOBS/$job/out.log"; fi
      [ -n "$src" ] && res="$(cat "$src" 2>/dev/null)"
      if [ -z "$(printf '%s' "$res" | tr -d '[:space:]')" ]; then
        reason="worker job $job finished but left no result to read; retry it"
      else
        local rtmp="$tdir/report.md.tmp.$$"
        if printf '%s\n' "$res" > "$rtmp" 2>/dev/null && mv -f "$rtmp" "$tdir/report.md"; then
          reason="report saved to $tdir/report.md"; rc=0
        else
          rm -f "$rtmp" 2>/dev/null; reason="could not save the report to $tdir/report.md"
        fi
      fi
    fi
  else
    shape="ship"
    if _factory_gate_ship "$wt" "$base" "$job" "$check" "$tdir"; then rc=0; fi
    reason="$_FG_REASON"
  fi
  verdict="not_done"; [ "$rc" = 0 ] && verdict="done"
  ej="$(_factory_evidence_json "$tid" "$shape" "$job" "$verdict" "$reason")"
  _factory_write_json "$ev" "$ej" || echo "warning: could not write $ev" >&2
  if [ "$shape" = "ship" ] && [ -n "${_FG_HEAD:-}" ]; then
    _task_update "$plan" "$tid" '.evidence=$e | .head_sha=$h' --arg e "$ev" --arg h "$_FG_HEAD" >/dev/null 2>&1 || true
  else
    _task_update "$plan" "$tid" '.evidence=$e' --arg e "$ev" >/dev/null 2>&1 || true
  fi
  if [ "$rc" = 0 ]; then echo "$tid done: $reason"; else echo "$tid not done: $reason"; fi
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Merge queue lock: one land at a time per repository (mkdir lock, pid + start-identity owner,
# provably-dead owners reclaimed; a live owner is never broken by age).
# ---------------------------------------------------------------------------------------------
_land_lock_dir() {
  local key; key="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s/locks/land-%s' "$OSRC_HOME" "$key"
}

# _land_lock_acquire <repo-root> <holder-description> -> rc0 holding (_LAND_LOCK set), rc1 timed out.
_land_lock_acquire() {
  local lk wait start now said=0 o_pid o_start v_pid v_start cur idrc dead corpse holder me age grace
  lk="$(_land_lock_dir "$1")"; mkdir -p "${lk%/*}" 2>/dev/null
  wait="${OSRC_LAND_LOCK_WAIT:-900}"; case "$wait" in ''|*[!0-9]*) wait=900 ;; esac
  grace="${OSRC_STATE_LOCK_STALE_SECS:-30}"
  me="${BASHPID:-$$}"; start="$(date +%s)"
  while :; do
    if _mkdir_claim "$lk"; then
      printf '%s %s\n' "$me" "$(_pid_start_identity "$me" 2>/dev/null)" > "$lk/owner.tmp" 2>/dev/null \
        && mv -f "$lk/owner.tmp" "$lk/owner" 2>/dev/null
      printf '%s (since %s)\n' "$2" "$(_factory_now)" > "$lk/holder" 2>/dev/null
      _LAND_LOCK="$lk"; return 0
    fi
    o_pid=""; o_start=""
    if [ -f "$lk/owner" ]; then
      { read -r o_pid o_start < "$lk/owner"; } 2>/dev/null || true
      case "$o_pid" in
        ''|*[!0-9]*) ;;
        *)
          cur="$(_pid_start_identity "$o_pid" 2>/dev/null)"; idrc=$?
          dead=0
          if [ "$idrc" -eq 2 ]; then dead=1
          elif [ "$idrc" -eq 0 ] && [ -n "$o_start" ] && [ "$cur" != "$o_start" ]; then dead=1; fi
          if [ "$dead" = 1 ]; then
            v_pid=""; v_start=""
            { read -r v_pid v_start < "$lk/owner"; } 2>/dev/null || true
            if [ "$v_pid" = "$o_pid" ] && [ "$v_start" = "$o_start" ]; then
              corpse="$lk.stale.$me.${RANDOM:-0}"
              mv "$lk" "$corpse" 2>/dev/null && rm -rf "$corpse" 2>/dev/null
              echo "[land] cleared a leftover merge-queue lock from a land that is no longer running (pid $o_pid)." >&2
              continue
            fi
          fi ;;
      esac
    else
      age="$(_mtime "$lk" 2>/dev/null)"; case "$age" in ''|*[!0-9]*) age=0 ;; esac
      if [ "$age" -gt 0 ] && [ $(( $(date +%s) - age )) -ge "$grace" ]; then
        corpse="$lk.stale.$me.${RANDOM:-0}"
        mv "$lk" "$corpse" 2>/dev/null && rm -rf "$corpse" 2>/dev/null
        continue
      fi
    fi
    holder="$(head -1 "$lk/holder" 2>/dev/null)"
    if [ "$said" = 0 ]; then
      echo "[land] waiting in the merge queue: ${holder:-another land} is merging into this repo (pid ${o_pid:-?}). Lands go one at a time." >&2
      said=1
    fi
    now="$(date +%s)"
    if [ $(( now - start )) -ge "$wait" ]; then
      echo "[land] gave up after ${wait}s waiting for: ${holder:-another land} (pid ${o_pid:-?}). If it is stuck, stop that process and run land again; OSRC_LAND_LOCK_WAIT sets the wait." >&2
      return 1
    fi
    sleep 1
  done
}

_land_lock_release() {
  [ -n "${_LAND_LOCK:-}" ] || return 0
  rm -f "$_LAND_LOCK/owner" "$_LAND_LOCK/holder" "$_LAND_LOCK/owner.tmp" 2>/dev/null
  rmdir "$_LAND_LOCK" 2>/dev/null || rm -rf "$_LAND_LOCK" 2>/dev/null
  _LAND_LOCK=""
}

# _land_checkout_of <root> <branch> -> path of the worktree that has <branch> checked out (empty = none).
_land_checkout_of() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk -v ref="refs/heads/$2" '/^worktree /{p=substr($0,10)} $0=="branch " ref {print p; exit}'
}

# _land_wake <id> <summary> -> best-effort wake event so a sleeping orchestrator hears about it.
_land_wake() {
  type _wake_append >/dev/null 2>&1 || return 0
  local eid; eid="land.$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').$(date +%s)"
  _wake_append "$(jq -cn --arg e "$eid" --arg s "$2" '{event_id:$e,kind:"land",state:"failed",task_summary:$s}')" >/dev/null 2>&1 || true
}

_land_cleanup() {
  if [ -n "${_LAND_IWT:-}" ] && [ -n "${_LAND_ROOT:-}" ]; then
    git -C "$_LAND_IWT" merge --abort >/dev/null 2>&1 || true
    git -C "$_LAND_ROOT" worktree remove --force "$_LAND_IWT" >/dev/null 2>&1 || rm -rf "$_LAND_IWT" 2>/dev/null
    git -C "$_LAND_ROOT" worktree prune >/dev/null 2>&1 || true
    _LAND_IWT=""
  fi
  _land_lock_release
}

_land_usage() {
  cat <<'EOF'
usage: outsourcerer land <task-id|job-id> [--plan P] [--check CMD] [--into BRANCH] [--pr] [--dry-run]
  Merges finished ship work into a branch, one land at a time per repo, only when it passes the
  done contract and the check still passes on the merged result.
  --plan P       plan the task belongs to (default: the current plan)
  --check CMD    check to run (default: the task's own check; required to verify a bare job)
  --into BRANCH  branch to land on (default: the plan's base branch, else the repo's current branch)
  --pr           push the branch and open a pull request instead of moving BRANCH
  --dry-run      do every step, but leave BRANCH and the task untouched
EOF
}

cmd_land() { ( _land_run "$@" ); }

# _land_run -- body of `land`, always in a subshell so its EXIT trap (integration worktree + lock
# cleanup) never replaces the main script's traps, and a die() anywhere still cleans up.
_land_run() {
  local target="" plan_arg="" check="" check_set=0 into="" pr=0 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan)    [ -n "${2:-}" ] || die "land --plan needs a plan name"; plan_arg="$2"; shift 2 ;;
      --check)   [ $# -ge 2 ] || die "land --check needs a command"; check="$2"; check_set=1; shift 2 ;;
      --into)    [ -n "${2:-}" ] || die "land --into needs a branch name"; into="$2"; shift 2 ;;
      --pr)      pr=1; shift ;;
      --dry-run) dry=1; shift ;;
      -h|--help) _land_usage; return 0 ;;
      -*)        die "land: unknown option $1 (see: outsourcerer land --help)" ;;
      *)         [ -z "$target" ] || die "land takes one task or job id (got '$target' and '$1')"; target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || { _land_usage >&2; exit 1; }
  have git || die "land needs git"
  have jq || die "the factory needs jq; install it (brew install jq / apt install jq) and try again"
  [ "$pr" = 1 ] && [ "$dry" = 1 ] && die "land: pick --pr or --dry-run, not both"

  local mode plan="" tid="" jid="" tj="" wt="" branch="" base="" title="" repo="" evf="" ev_dir="" pd=""
  case "$target" in
    t[0-9]*) mode=task ;;
    *) case "$target" in */*|*..*) die "land: '$target' is not a task or job id" ;; esac
       [ -d "$OSRC_JOBS/$target" ] || die "land: no task or job named '$target' (tasks look like t3; see: outsourcerer task ls)"
       mode=job ;;
  esac

  if [ "$mode" = task ]; then
    type _task_get >/dev/null 2>&1 || die "land: the task store is not loaded (factory-tasks.sh missing); update outsourcerer"
    plan="$(_plan_resolve ${plan_arg:+"$plan_arg"})" || exit 1
    [ -n "$plan" ] || die "land: no plan given and no current plan set (use --plan or: outsourcerer plan use <name>)"
    tid="$target"
    tj="$(_task_get "$plan" "$tid" 2>/dev/null)" || die "land: there is no task $tid in plan $plan (see: outsourcerer task ls)"
    pd="$(_plan_dir "$plan")"; ev_dir="$pd/tasks/$tid"; evf="$ev_dir/evidence.json"
    local shape state landed
    shape="$(jq -r '.shape // "ship"' <<<"$tj")"; state="$(jq -r '.state // ""' <<<"$tj")"
    landed="$(jq -r '.landed // false' <<<"$tj")"
    [ "$shape" = scout ] && die "land: $tid is a scout task; it produces a report, not code, so there is nothing to merge"
    [ "$state" = canceled ] && die "land: $tid was canceled; retry it first if you still want it"
    [ "$landed" = true ] && { echo "$tid is already landed ($(jq -r '.landed_sha // "" | .[0:12]' <<<"$tj") on $(jq -r '.landed_into // "?"' <<<"$tj")); nothing to do."; return 0; }
    jid="$(jq -r '.job // ""' <<<"$tj")"
    wt="$(jq -r '.worktree // ""' <<<"$tj")"; branch="$(jq -r '.branch // ""' <<<"$tj")"
    base="$(jq -r '.base_sha // ""' <<<"$tj")"; title="$(jq -r '.title // ""' <<<"$tj")"
    [ "$check_set" = 1 ] || check="$(jq -r '.check // ""' <<<"$tj")"
    repo="$(jq -r '.repo // ""' "$pd/plan.json" 2>/dev/null)"
    [ -n "$into" ] || into="$(jq -r '.base_branch // ""' "$pd/plan.json" 2>/dev/null)"
  else
    jid="$target"; ev_dir="$OSRC_JOBS/$jid"; evf="$ev_dir/evidence.json"
    local wj="$OSRC_JOBS/$jid/worktree.json"
    [ -f "$wj" ] || die "land: job $jid did not run in its own worktree, so there is no branch to land (launch it with --worktree)"
    title="$(jq -r '.task_summary // .task // ""' "$OSRC_JOBS/$jid/meta.json" 2>/dev/null | head -1 | cut -c1-72)"
  fi
  if [ -n "$jid" ] && [ -f "$OSRC_JOBS/$jid/worktree.json" ]; then
    [ -n "$wt" ] || wt="$(jq -r '.path // ""' "$OSRC_JOBS/$jid/worktree.json")"
    [ -n "$branch" ] || branch="$(jq -r '.branch // ""' "$OSRC_JOBS/$jid/worktree.json")"
    [ -n "$base" ] || base="$(jq -r '.base_sha // ""' "$OSRC_JOBS/$jid/worktree.json")"
  fi
  [ -n "$wt" ] || die "land: no worktree is on record for $target, so there is nothing to merge"
  case "$wt" in *'..'*) die "land: refusing a worktree path containing '..': $wt" ;; esac

  # Repository: the plan's repo, else the main checkout that owns the worker's worktree.
  if [ -z "$repo" ]; then
    case "$wt" in */.outsourcerer/worktrees/*) repo="${wt%/.outsourcerer/worktrees/*}" ;; esac
    [ -n "$repo" ] || repo="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)"
  fi
  local root; root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || die "land: $repo is not a git repository"
  root="$(cd "$root" && pwd -P)"
  if [ -z "$into" ]; then
    into="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
      || die "land: $root has a detached HEAD, so there's no branch to land on; pass --into <branch>"
  fi
  git check-ref-format --branch "$into" >/dev/null 2>&1 || die "land: '$into' is not a valid branch name"
  git -C "$root" rev-parse --verify --quiet "refs/heads/$into" >/dev/null || die "land: branch '$into' does not exist in $root"

  local label; if [ "$mode" = task ]; then label="$plan/$tid"; else label="$jid"; fi
  [ -n "$title" ] || title="${branch:-$label}"
  local msg="land($label): $title"

  # ---- 1. Done contract (outside the queue lock: it only reads the worker's worktree, and the exact
  #         head it verifies is what gets merged, so later edits there cannot sneak in). ----
  local head reason
  if [ "$mode" = task ]; then
    if [ "$check_set" = 1 ]; then reason="$(_factory_done_check "$plan" "$tid" "$check")"
    else reason="$(_factory_done_check "$plan" "$tid")"; fi \
      || die "land: not landing $label. $reason"
    head="$(jq -r '.head_sha // ""' "$evf" 2>/dev/null)"
  else
    _factory_gate_reset
    mkdir -p "$ev_dir" 2>/dev/null
    if _factory_gate_ship "$wt" "$base" "$jid" "$check" "$ev_dir"; then
      _factory_write_json "$evf" "$(_factory_evidence_json "$jid" ship "$jid" done "$_FG_REASON")" || true
      reason="$jid done: $_FG_REASON"
    else
      _factory_write_json "$evf" "$(_factory_evidence_json "$jid" ship "$jid" not_done "$_FG_REASON")" || true
      die "land: not landing $jid. $_FG_REASON"
    fi
    head="$_FG_HEAD"
    [ -n "$check" ] || echo "[land] note: no --check given; the merged result will not be re-verified." >&2
  fi
  [ -n "$head" ] || die "land: the done check passed but recorded no head commit; run land again"
  echo "[land] $reason" >&2

  # ---- 2. The merge queue (per-repo lock) ----
  _LAND_ROOT="$root"; _LAND_IWT=""; _LAND_LOCK=""
  trap '_land_cleanup' EXIT
  trap 'exit 130' INT TERM
  _land_lock_acquire "$root" "land $label into $into" || exit 1
  [ "$mode" = task ] && type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" land_started "into $into" >/dev/null 2>&1

  local before; before="$(git -C "$root" rev-parse "refs/heads/$into")"
  if git -C "$root" merge-base --is-ancestor "$head" "$before" 2>/dev/null; then
    echo "$label is already contained in $into (${before:0:12}); nothing to merge."
    if [ "$mode" = task ] && [ "$dry" = 0 ] && [ "$pr" = 0 ]; then
      _task_update "$plan" "$tid" '.landed=true | .state="done" | .landed_sha=$m | .landed_into=$i' \
        --arg m "$before" --arg i "$into" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # Fail fast (before any work) if the target's checkout can't be fast-forwarded safely.
  local co=""
  if [ "$pr" = 0 ] && [ "$dry" = 0 ]; then
    co="$(_land_checkout_of "$root" "$into")"
    if [ -n "$co" ] && ! _crew_worktree_clean "$co"; then
      die "land: $into is checked out at $co with uncommitted changes; commit or stash them there, then run land again (nothing was changed)"
    fi
  fi

  # ---- 3. Fresh integration worktree at the target tip; no-ff merge of the VERIFIED head ----
  local lid nohooks; lid="land-$(_new_job_id)"
  nohooks="$OSRC_HOME/land/nohooks"; mkdir -p "$nohooks" "$root/.outsourcerer/worktrees" 2>/dev/null
  _LAND_IWT="$root/.outsourcerer/worktrees/$lid"
  git -C "$root" worktree add -q --detach "$_LAND_IWT" "$before" >/dev/null 2>&1 \
    || { _LAND_IWT=""; die "land: could not create a scratch worktree to merge in (under $root/.outsourcerer/worktrees)"; }
  local -a gc=(-c "core.hooksPath=$nohooks" -c commit.gpgsign=false)
  if [ -z "$(git -C "$root" config user.email 2>/dev/null)" ]; then
    gc+=(-c user.name=outsourcerer -c user.email=outsourcerer@users.noreply.github.com)
  fi
  local mlog="$ev_dir/land-merge.log"; mkdir -p "$ev_dir" 2>/dev/null
  local land_json now_ts
  if ! git -C "$_LAND_IWT" "${gc[@]}" merge --no-ff --no-edit -m "$msg" "$head" > "$mlog" 2>&1; then
    local conf; conf="$(git -C "$_LAND_IWT" diff --name-only --diff-filter=U 2>/dev/null | head -10 | tr '\n' ' ')"
    git -C "$_LAND_IWT" merge --abort >/dev/null 2>&1 || true
    now_ts="$(_factory_now)"
    land_json="$(jq -cn --arg into "$into" --arg before "$before" --arg head "$head" --arg files "$conf" --arg ts "$now_ts" \
      --arg mode "$( [ "$dry" = 1 ] && echo dry-run || echo merge)" \
      '{into:$into,target_before:$before,head_sha:$head,verdict:"conflict",conflicts:($files|split(" ")|map(select(.!=""))),mode:$mode,ts:$ts}')"
    _land_record "$evf" "$land_json"
    if [ "$mode" = task ] && [ "$dry" = 0 ]; then
      type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" land_conflict "${conf:-unknown files}" >/dev/null 2>&1
      _land_wake "$label" "land $label: merge conflict with $into"
    fi
    die "land: not landed. ${branch:-$label} conflicts with $into in: ${conf:-unknown files}. Bring the branch up to date with $into (or retry the task), then land again. $into is untouched."
  fi
  local merged; merged="$(git -C "$_LAND_IWT" rev-parse HEAD)"

  # ---- 4. Re-run the check on the MERGED result ----
  _FG_CHECK_RC=""; _FG_SIG=""; _FG_TAIL=""
  local crc=0 cverdict="none"
  if [ -n "$check" ]; then
    _factory_check_run "$_LAND_IWT" "$check" "$ev_dir/land-check.out"; crc=$?
    if [ "$crc" = 0 ]; then cverdict="pass"; else cverdict="fail"; fi
  fi
  now_ts="$(_factory_now)"
  local lmode; if [ "$dry" = 1 ]; then lmode="dry-run"; elif [ "$pr" = 1 ]; then lmode="pr"; else lmode="ff"; fi
  _land_json() { # <verdict> [pr_url]
    jq -cn --arg into "$into" --arg before "$before" --arg head "$head" --arg merged "$merged" \
      --arg cmd "$check" --arg rc "${_FG_CHECK_RC:-}" --arg sig "${_FG_SIG:-}" --arg tail "${_FG_TAIL:-}" \
      --arg verdict "$1" --arg pr "${2:-}" --arg mode "$lmode" --arg ts "$now_ts" \
      '{into:$into,target_before:$before,head_sha:$head,merged_sha:$merged,
        check:{cmd:$cmd,rc:(if $rc=="" then null else ($rc|tonumber) end),signature:$sig,tail:$tail},
        verdict:$verdict,mode:$mode,ts:$ts} + (if $pr=="" then {} else {pr_url:$pr} end)'
  }
  if [ "$cverdict" = fail ]; then
    _land_record "$evf" "$(_land_json check_failed)"
    local why="merge breaks check"
    case "$crc" in 124) why="merge breaks check (the check timed out)" ;; 125) why="merge breaks check (the check could not start)" ;; esac
    if [ "$mode" = task ] && [ "$dry" = 0 ]; then
      _task_update "$plan" "$tid" '.state="failed" | .result=$r' --arg r "$why" >/dev/null 2>&1 || true
      type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" land_failed "$why" >/dev/null 2>&1
      _land_wake "$label" "land $label: $why on $into"
    fi
    echo "[land] last lines of the check:" >&2; printf '%s\n' "${_FG_TAIL:-}" | tail -n 8 >&2
    die "land: not landed. After merging into $into the check fails (exit $crc): $check. $into is untouched; details in $ev_dir/land-check.out."
  fi
  local cnote="the check passed on the merged result"; [ "$cverdict" = none ] && cnote="no check set, merged result not re-verified"

  # ---- 5a. Dry run: stop before anything moves ----
  if [ "$dry" = 1 ]; then
    _land_record "$evf" "$(_land_json dry_run_ok)"
    echo "dry run: $label would land on $into as ${merged:0:12} (merge of ${head:0:12}); $cnote. Nothing was moved."
    return 0
  fi

  # ---- 5b. --pr: push the verified head to its branch and open a PR (explicit opt-in only) ----
  if [ "$pr" = 1 ]; then
    have gh || die "land --pr needs the GitHub CLI (gh); install it, or land without --pr"
    [ -n "$branch" ] || die "land --pr: no branch name is on record to push"
    git -C "$root" remote get-url origin >/dev/null 2>&1 || die "land --pr: this repo has no 'origin' remote to push to"
    git -C "$root" push -q origin "$head:refs/heads/$branch" >/dev/null 2>&1 \
      || die "land --pr: could not push $branch to origin; check your access, then run land --pr again"
    local body url
    body="$(printf 'Landed by outsourcerer.\n\n- work: %s\n- head: %s\n- %s (merged against %s at %s)\n' "$label" "$head" "$cnote" "$into" "${before:0:12}")"
    url="$(cd "$root" && gh pr create --base "$into" --head "$branch" --title "$msg" --body "$body" 2>&1)" \
      || die "land --pr: gh could not open the pull request: $(printf '%s' "$url" | tail -1)"
    url="$(printf '%s\n' "$url" | grep -Eo 'https?://[^[:space:]]+' | tail -1)"
    _land_record "$evf" "$(_land_json pr_opened "$url")"
    if [ "$mode" = task ]; then
      _task_update "$plan" "$tid" '.pr=$u' --arg u "$url" >/dev/null 2>&1 || true
      type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" pr_opened "$url" >/dev/null 2>&1
    fi
    echo "opened a pull request for $label into $into: ${url:-?} ($cnote). $into was not moved."
    return 0
  fi

  # ---- 5c. Fast-forward the target, never clobbering a checkout ----
  local now_tip; now_tip="$(git -C "$root" rev-parse "refs/heads/$into")"
  [ "$now_tip" = "$before" ] || die "land: $into moved while landing (now ${now_tip:0:12}); nothing was changed, run land again"
  co="$(_land_checkout_of "$root" "$into")"
  if [ -z "$co" ]; then
    git -C "$root" update-ref -m "$msg" "refs/heads/$into" "$merged" "$before" >/dev/null 2>&1 \
      || die "land: could not move $into (it changed underneath us); nothing was changed, run land again"
  else
    _crew_worktree_clean "$co" || die "land: $into is checked out at $co with uncommitted changes; commit or stash them there, then run land again (nothing was changed)"
    [ "$(git -C "$co" rev-parse HEAD 2>/dev/null)" = "$before" ] || die "land: the checkout of $into at $co is not at the expected commit; nothing was changed, run land again"
    git -C "$co" -c "core.hooksPath=$nohooks" merge --ff-only -q "$merged" >/dev/null 2>&1 \
      || die "land: could not fast-forward $into in $co (an untracked file there may be in the way); nothing was changed"
  fi
  [ "$(git -C "$root" rev-parse "refs/heads/$into")" = "$merged" ] || die "land: $into did not end up at the merged commit; check it by hand"
  _land_record "$evf" "$(_land_json landed)"
  if [ "$mode" = task ]; then
    _task_update "$plan" "$tid" '.landed=true | .state="done" | .landed_sha=$m | .landed_into=$i | .evidence=$e' \
      --arg m "$merged" --arg i "$into" --arg e "$evf" >/dev/null 2>&1 || true
    type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" landed "$into at ${merged:0:12}" >/dev/null 2>&1
  fi
  echo "landed $label on $into at ${merged:0:12} (merge of ${head:0:12}); $cnote."
  return 0
}

# _land_record <evidence.json> <land-json> -> merge {land: ...} into the evidence file (atomic).
_land_record() {
  local evf="$1" cur="{}"
  [ -s "$evf" ] && cur="$(cat "$evf" 2>/dev/null)"
  printf '%s' "$cur" | jq -e . >/dev/null 2>&1 || cur="{}"
  _factory_write_json "$evf" "$(jq -cn --argjson c "$cur" --argjson l "$2" '$c + {land:$l}')" \
    || echo "warning: could not record the land result in $evf" >&2
}
