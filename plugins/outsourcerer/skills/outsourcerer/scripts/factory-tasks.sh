# factory-tasks.sh -- Outsourcerer software factory, track B: the durable plan/task graph.
# Sourced by outsourcerer.sh (never run on its own). Defines functions only, no side effects.
#
# State (all under $OSRC_HOME, see CONTRACT.md "Data model"):
#   plans/current                 default plan name
#   plans/<plan>/plan.json        {"schema":1,"name","goal","repo","base_branch","created","updated"}
#   plans/<plan>/tasks/<tid>.json one task (tid = t1, t2, ... allocated under the plan lock)
#   plans/<plan>/tasks/<tid>/     brief.md (the exact prompt a worker got), evidence.json, report.md
#   plans/<plan>/events.jsonl     append-only {"ts","plan","task","event","from","to","note"}
#   plans/<plan>/.lock/           mkdir lock (owner = "pid start-identity"), stale holders reclaimed
#
# Library API (tracks C and D call these by name):
#   _plan_dir <plan>                     -> prints the plan directory path
#   _plan_resolve [plan]                 -> prints the plan name (arg, else current); dies if none
#   _task_get <plan> <tid>               -> prints task JSON; rc1 if missing or damaged
#   _task_update <plan> <tid> <jq-filter> [jq args...]
#                                        -> atomic under the plan lock, bumps .updated, logs a
#                                           state event when .state changes (note: FACTORY_EVENT_NOTE)
#   _task_list <plan>                    -> JSON array of tasks (id order); damaged files skipped
#   _task_view <plan>                    -> like _task_list, plus .derived (ready|blocked|<state>),
#                                           .blocked_by [{id,state}] and .depth
#   _task_ready <plan>                   -> newline list of ready tids (dependency order, then id)
#   _task_brief <plan> <tid>             -> writes tasks/<tid>/brief.md, prints its path
#   _task_dispatch <plan> <tid>          -> claim todo->running, brief, launch through bg; prints job id
#   _task_event <plan> <tid> <event> [note]
#   _task_new <plan> <task-json-fields>  -> allocates a tid under the lock, writes the task, prints tid

# ---------------------------------------------------------------- basics

_factory_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_factory_need_jq() {
  have jq || die "the plan and task commands need jq. Install it (brew install jq, apt install jq, or winget install jqlang.jq) and try again."
}

_plans_root() { printf '%s/plans' "$OSRC_HOME"; }

_plan_name_ok() {
  case "${1:-}" in
    ''|current|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

_task_id_ok() {
  case "${1:-}" in t[1-9]*) ;; *) return 1 ;; esac
  case "${1#t}" in *[!0-9]*) return 1 ;; esac
  return 0
}

_plan_dir() { printf '%s/%s' "$(_plans_root)" "$1"; }

_plan_current() {
  local c=""
  [ -f "$(_plans_root)/current" ] && c="$(head -n 1 "$(_plans_root)/current" 2>/dev/null | tr -d '\r\n')"
  _plan_name_ok "$c" || return 1
  printf '%s' "$c"
}

# _plan_resolve [plan] -> the plan name to use: the argument, else the current plan. Dies with a
# next step when neither names an existing plan.
_plan_resolve() {
  local p="${1:-}"
  if [ -z "$p" ]; then
    p="$(_plan_current)" || die "no plan selected. Make one with: outsourcerer plan new <name> --goal \"...\" (or pass --plan <name>)."
  fi
  _plan_name_ok "$p" || die "'$p' is not a valid plan name (letters, digits, dot, dash, underscore; up to 64)."
  [ -f "$(_plan_dir "$p")/plan.json" ] || die "there is no plan named '$p'. See your plans with: outsourcerer plan ls"
  printf '%s' "$p"
}

# _factory_write_json <path> <json> -> validate, then write via tmp + mv (atomic on one filesystem).
_factory_write_json() {
  local path="$1" json="$2" tmp
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || { echo "outsourcerer: refusing to write broken JSON to $path" >&2; return 1; }
  tmp="$path.tmp.$$.${RANDOM:-0}"
  ( umask 077; printf '%s\n' "$json" > "$tmp" ) 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# _factory_write_file <path> < stdin -> same atomic pattern for text (brief.md, report.md).
_factory_write_file() {
  local path="$1" tmp
  tmp="$path.tmp.$$.${RANDOM:-0}"
  ( umask 077; cat > "$tmp" ) 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# ---------------------------------------------------------------- the plan lock
# mkdir is the portable atomic (no flock on stock macOS). The owner file records "pid start-identity"
# so a waiter can prove the holder died and reclaim, the same pattern as _state_lock_acquire. Two
# extra escape hatches: an ownerless lock older than 30s (holder killed between mkdir and publishing),
# and any lock older than OSRC_PLAN_LOCK_STALE_SECS (default 120s): nothing legitimately holds a plan
# lock that long, because worker launches happen OUTSIDE the lock. The lock is re-entrant within one
# process tree (a nested call made while we hold it, including from a command substitution, proceeds).
_FACTORY_LOCK_PLAN=""
_FACTORY_LOCK_DEPTH=0

_plan_lock() {
  local plan="$1" lock owner tries=0 o_pid o_start cur _rc age stale me corpse
  if [ "$_FACTORY_LOCK_PLAN" = "$plan" ] && [ "$_FACTORY_LOCK_DEPTH" -gt 0 ]; then
    _FACTORY_LOCK_DEPTH=$((_FACTORY_LOCK_DEPTH + 1)); return 0
  fi
  lock="$(_plan_dir "$plan")/.lock"; owner="$lock/owner"
  stale="${OSRC_PLAN_LOCK_STALE_SECS:-120}"; case "$stale" in ''|*[!0-9]*) stale=120 ;; esac
  me="${BASHPID:-$$}"
  while [ "$tries" -lt "${OSRC_PLAN_LOCK_TRIES:-150}" ]; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s %s\n' "$me" "$(_pid_start_identity "$me" 2>/dev/null)" > "$lock/owner.$me" 2>/dev/null \
        && mv -f "$lock/owner.$me" "$owner" 2>/dev/null
      _FACTORY_LOCK_PLAN="$plan"; _FACTORY_LOCK_DEPTH=1
      return 0
    fi
    age="$(_mtime "$lock" 2>/dev/null || echo 0)"; case "$age" in ''|*[!0-9]*) age=0 ;; esac
    [ "$age" -gt 0 ] && age=$(( $(date +%s) - age )) || age=0
    if [ -f "$owner" ]; then
      o_pid=""; o_start=""
      { read -r o_pid o_start < "$owner"; } 2>/dev/null || true
      case "$o_pid" in
        ''|*[!0-9]*) ;;
        *)
          _rc=0; cur="$(_pid_start_identity "$o_pid" 2>/dev/null)" || _rc=$?
          if [ "$_rc" -eq 2 ] || { [ "$_rc" -eq 0 ] && [ -n "$o_start" ] && [ "$cur" != "$o_start" ]; } \
             || ! kill -0 "$o_pid" 2>/dev/null || [ "$age" -ge "$stale" ]; then
            corpse="$lock.stale.$me.${RANDOM:-0}"
            mv "$lock" "$corpse" 2>/dev/null && rm -rf "$corpse" 2>/dev/null
            continue
          fi ;;
      esac
    elif [ "$age" -ge 30 ]; then
      corpse="$lock.stale.$me.${RANDOM:-0}"
      mv "$lock" "$corpse" 2>/dev/null && rm -rf "$corpse" 2>/dev/null
      continue
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  echo "outsourcerer: plan '$plan' is busy (another command holds its lock). Try again in a moment." >&2
  return 1
}

_plan_unlock() {
  local plan="$1" lock
  [ "$_FACTORY_LOCK_PLAN" = "$plan" ] || return 0
  _FACTORY_LOCK_DEPTH=$((_FACTORY_LOCK_DEPTH - 1))
  [ "$_FACTORY_LOCK_DEPTH" -gt 0 ] && return 0
  lock="$(_plan_dir "$plan")/.lock"
  rm -f "$lock/owner" "$lock"/owner.* 2>/dev/null
  rmdir "$lock" 2>/dev/null || true
  _FACTORY_LOCK_PLAN=""; _FACTORY_LOCK_DEPTH=0
}

# ---------------------------------------------------------------- events + wake

# _task_event_full <plan> <tid> <event> <from> <to> <note> -> one line in events.jsonl. A single
# O_APPEND write of one short line, so it is safe with or without the plan lock held.
_task_event_full() {
  local plan="$1" tid="$2" ev="$3" from="${4:-}" to="${5:-}" note="${6:-}" line
  line="$(jq -cn --arg ts "$(_factory_now)" --arg plan "$plan" --arg task "$tid" --arg event "$ev" \
           --arg from "$from" --arg to "$to" --arg note "$note" \
           '{ts:$ts,plan:$plan,task:$task,event:$event,from:$from,to:$to,note:($note|.[0:2000])}')" || return 1
  printf '%s\n' "$line" >> "$(_plan_dir "$plan")/events.jsonl" 2>/dev/null
}

# _task_event <plan> <tid> <event> [note]
_task_event() { _task_event_full "$1" "$2" "$3" "" "" "${4:-}"; }

# _factory_wake <plan> <tid> <state> <summary> -> push a held/failed task to the heartbeat wake
# queue so a headless orchestrator hears about it. Best-effort: never fails the caller.
_factory_wake() {
  type _wake_append >/dev/null 2>&1 || return 0
  local plan="$1" tid="$2" st="$3" summary="$4" eid
  eid="factory.$plan.$tid.$st.$(date +%s).${RANDOM:-0}"
  _wake_append "$(jq -cn --arg event_id "$eid" --arg plan "$plan" --arg task "$tid" --arg st "$st" --arg s "$summary" \
    '{event_id:$event_id,kind:"factory-task",plan:$plan,task:$task,state:"blocked",task_state:$st,task_summary:($s|.[0:200])}')" \
    >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------- task store

_task_file() { printf '%s/tasks/%s.json' "$(_plan_dir "$1")" "$2"; }
_task_dir()  { printf '%s/tasks/%s' "$(_plan_dir "$1")" "$2"; }

# _task_get <plan> <tid> -> task JSON on stdout; rc1 (with one plain line on stderr) when the task
# does not exist or its file is damaged.
_task_get() {
  local plan="$1" tid="$2" f out
  _task_id_ok "$tid" || { echo "outsourcerer: '$tid' is not a task id (they look like t1, t2, ...)." >&2; return 1; }
  f="$(_task_file "$plan" "$tid")"
  [ -f "$f" ] || { echo "outsourcerer: plan '$plan' has no task $tid. See its tasks with: outsourcerer task ls --plan $plan" >&2; return 1; }
  out="$(jq -ce 'if type == "object" and (.id|type) == "string" then . else error("bad") end' "$f" 2>/dev/null)" \
    || { echo "outsourcerer: task file $f is damaged (not valid task JSON). Fix it by hand or remove it." >&2; return 1; }
  printf '%s\n' "$out"
}

# _task_list <plan> -> JSON array of every readable task, sorted by numeric id. A damaged file is
# skipped with a warning instead of hiding every other task.
_task_list() {
  local plan="$1" f td
  td="$(_plan_dir "$plan")/tasks"
  {
    for f in "$td"/t*.json; do
      [ -f "$f" ] || continue
      jq -ce 'if type == "object" and (.id|type) == "string" then . else error("bad") end' "$f" 2>/dev/null \
        || echo "outsourcerer: skipping damaged task file $f" >&2
    done
  } | jq -cs 'sort_by(.id | ltrimstr("t") | tonumber? // 0)'
}

# Shared jq: derive ready/blocked + dependency depth from the stored states (never stored).
_FACTORY_JQ_VIEW='
def idn: (.id | ltrimstr("t") | tonumber? // 0);
def view:
  . as $all
  | (reduce $all[] as $t ({}; .[$t.id] = $t)) as $by
  | (reduce ($all | sort_by(idn))[] as $t ({};
        .[$t.id] = (if (($t.deps // []) | length) == 0 then 0
                    else 1 + ([ ($t.deps // [])[] as $d | (.[$d] // 0) ] | max) end))) as $depth
  | map(. as $t
      | ([ ($t.deps // [])[] as $d | {id: $d, state: ($by[$d].state // "missing")} | select(.state != "done") ]) as $bl
      | . + {depth: ($depth[$t.id] // 0), blocked_by: $bl,
             derived: (if $t.state == "todo" then (if ($bl | length) == 0 then "ready" else "blocked" end)
                       else $t.state end)});
'

_task_view() { _task_list "$1" | jq -c "$_FACTORY_JQ_VIEW view"; }

# _task_ready <plan> -> ready tids, one per line: shallower dependency depth first, then id.
_task_ready() {
  _task_list "$1" | jq -r "$_FACTORY_JQ_VIEW view | map(select(.derived == \"ready\")) | sort_by([.depth, idn]) | .[].id"
}

# _task_update_locked <plan> <tid> <filter> [jq args...] -> the write half of _task_update. Caller
# holds the plan lock. Sets _FACTORY_LAST_FROM/_FACTORY_LAST_TO for the caller's wake decision.
_FACTORY_LAST_FROM=""; _FACTORY_LAST_TO=""
_task_update_locked() {
  local plan="$1" tid="$2" filter="$3" cur new from to now f
  shift 3
  _FACTORY_LAST_FROM=""; _FACTORY_LAST_TO=""
  cur="$(_task_get "$plan" "$tid")" || return 1
  now="$(_factory_now)"
  new="$(printf '%s' "$cur" | jq -ce --arg __now "$now" "$@" "($filter) | .updated = \$__now" 2>/dev/null)" || {
    echo "outsourcerer: could not update $plan/$tid (the change did not apply to this task as it stands)." >&2; return 1; }
  f="$(_task_file "$plan" "$tid")"
  _factory_write_json "$f" "$new" || { echo "outsourcerer: could not save $f" >&2; return 1; }
  from="$(printf '%s' "$cur" | jq -r '.state // ""')"; to="$(printf '%s' "$new" | jq -r '.state // ""')"
  if [ "$from" != "$to" ]; then
    _task_event_full "$plan" "$tid" state "$from" "$to" "${FACTORY_EVENT_NOTE:-}" || true
    _FACTORY_LAST_FROM="$from"; _FACTORY_LAST_TO="$to"
  fi
  return 0
}

# _task_wake_if_needed <plan> <tid> -> after an update: a task that just became held or failed
# needs the captain, so tell the heartbeat. Called OUTSIDE the plan lock.
_task_wake_if_needed() {
  local plan="$1" tid="$2" t title why
  case "$_FACTORY_LAST_TO" in held|failed) ;; *) return 0 ;; esac
  t="$(_task_get "$plan" "$tid" 2>/dev/null)" || return 0
  title="$(printf '%s' "$t" | jq -r '.title // ""')"
  if [ "$_FACTORY_LAST_TO" = held ]; then why="$(printf '%s' "$t" | jq -r '.hold.reason // ""')"
  else why="$(printf '%s' "$t" | jq -r '.result // ""')"; fi
  _factory_wake "$plan" "$tid" "$_FACTORY_LAST_TO" "plan $plan task $tid $_FACTORY_LAST_TO: $title${why:+ ($why)}"
}

# _task_update <plan> <tid> <jq-filter> [--arg k v | --argjson k v ...]
# Applies the filter to the task atomically under the plan lock and bumps .updated. A filter that
# errors (for example `if .state != "todo" then error("no") else ... end`) changes nothing and
# returns 1, which makes guarded transitions race-free. A .state change appends a "state" event
# (note from FACTORY_EVENT_NOTE) and, for held/failed, a wake event.
_task_update() {
  local plan="$1" tid="$2" rc=0
  _plan_lock "$plan" || return 1
  _task_update_locked "$@" || rc=1
  _plan_unlock "$plan"
  [ "$rc" -eq 0 ] && _task_wake_if_needed "$plan" "$tid"
  return "$rc"
}

# _task_new <plan> <json-object> -> allocate the next tid under the lock, merge the fields over the
# defaults, validate deps exist, write the task, print the tid. Deps can only name tasks that already
# exist, so the graph is acyclic by construction.
_task_new() {
  local plan="$1" fields="$2" n max=0 f tid now task missing
  _plan_lock "$plan" || return 1
  for f in "$(_plan_dir "$plan")"/tasks/t*.json "$(_plan_dir "$plan")"/tasks/t*; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.json}"; n="${n#t}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max="$n"
  done
  tid="t$((max + 1))"
  missing="$(printf '%s' "$fields" | jq -r '(.deps // [])[]' | while IFS= read -r d; do
    [ -f "$(_task_file "$plan" "$d")" ] || printf '%s ' "$d"; done)"
  if [ -n "$missing" ]; then
    _plan_unlock "$plan"
    echo "outsourcerer: the dependency ${missing% } does not exist in plan '$plan'. Add that task first (see: outsourcerer task ls)." >&2
    return 1
  fi
  now="$(_factory_now)"
  task="$(jq -cn --arg id "$tid" --arg plan "$plan" --arg now "$now" --argjson f "$fields" '
    {schema:1,id:$id,plan:$plan,title:"",shape:"scout",state:"todo",deps:[],prompt:"",spec:"",check:"",
     verb:"",model:"",provider:"",deliver:"local",retries:1,attempts:0,job:"",jobs:[],
     worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},
     result:"",evidence:"",flow:{name:"",stage:""},created:$now,updated:$now}
    * $f | .id = $id | .plan = $plan
    | if .verb == "" then .verb = (if .shape == "ship" then "edit" else "run" end) else . end
    | if .prompt == "" then .prompt = .title else . end')" || { _plan_unlock "$plan"; return 1; }
  mkdir -p "$(_task_dir "$plan" "$tid")" 2>/dev/null
  if ! _factory_write_json "$(_task_file "$plan" "$tid")" "$task"; then
    _plan_unlock "$plan"; return 1
  fi
  _task_event_full "$plan" "$tid" created "" "$(printf '%s' "$task" | jq -r .state)" "$(printf '%s' "$task" | jq -r .title)" || true
  _plan_unlock "$plan"
  printf '%s\n' "$tid"
}

# ---------------------------------------------------------------- context handoff

# _factory_trim <max-chars> < text -> text capped at max chars (by character, not byte, so UTF-8
# never splits), with a visible marker when cut.
_factory_trim() {
  jq -Rrs --argjson n "$1" 'if length > $n then .[0:$n] + "\n[... trimmed; the full text is at the path below]" else . end'
}

# _task_output_path <plan> <task-json> -> the best full-output file for a task: its report.md, else
# its job's last.txt. Empty when there is none.
_task_output_path() {
  local plan="$1" t="$2" tid job p
  tid="$(printf '%s' "$t" | jq -r .id)"; job="$(printf '%s' "$t" | jq -r '.job // ""')"
  p="$(_task_dir "$plan" "$tid")/report.md"
  [ -s "$p" ] && { printf '%s' "$p"; return 0; }
  if [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ]; then printf '%s' "$OSRC_JOBS/$job/last.txt"; return 0; fi
  return 1
}

# _task_brief <plan> <tid> -> write tasks/<tid>/brief.md and print its path. This is the ONLY context
# a worker gets beyond the repo, so it carries: the plan goal, the task, the spec, the done rules,
# every direct dependency's result (bounded, with the path to the full text), and the captain's
# decisions. Bounded: spec inline up to 64KB, each dependency's output up to ~4KB.
_task_brief() {
  local plan="$1" tid="$2" t pj goal repo base title shape prompt spec check deps d dt dshape dtitle
  local dres out_path out_txt dbr dhead djob ans dans ddir brief attempts prev reason until sz
  t="$(_task_get "$plan" "$tid")" || return 1
  pj="$(jq -c . "$(_plan_dir "$plan")/plan.json" 2>/dev/null)" || pj='{}'
  goal="$(printf '%s' "$pj" | jq -r '.goal // ""')"
  repo="$(printf '%s' "$pj" | jq -r '.repo // ""')"
  base="$(printf '%s' "$pj" | jq -r '.base_branch // ""')"
  title="$(printf '%s' "$t" | jq -r '.title // ""')"
  shape="$(printf '%s' "$t" | jq -r '.shape // "scout"')"
  prompt="$(printf '%s' "$t" | jq -r '.prompt // ""')"
  spec="$(printf '%s' "$t" | jq -r '.spec // ""')"
  check="$(printf '%s' "$t" | jq -r '.check // ""')"
  attempts="$(printf '%s' "$t" | jq -r '.attempts // 0')"
  prev="$(printf '%s' "$t" | jq -r '.result // ""')"
  ans="$(printf '%s' "$t" | jq -r '.hold.answer // ""')"
  reason="$(printf '%s' "$t" | jq -r '.hold.reason // ""')"
  ddir="$(_task_dir "$plan" "$tid")"; mkdir -p "$ddir" 2>/dev/null
  brief="$ddir/brief.md"
  {
    printf '# Task %s/%s: %s\n\n' "$plan" "$tid" "$title"
    [ -n "$goal" ] && printf 'Plan goal: %s\n' "$goal"
    if [ -n "$repo" ]; then
      printf 'Repository: %s%s\n' "$repo" "${base:+ (base branch: $base)}"
    fi
    printf 'Task type: %s\n\n' "$( [ "$shape" = ship ] && echo 'ship (you change code and commit it)' || echo 'scout (you investigate and write up; you change nothing)')"
    printf '## Your task\n\n%s\n\n' "$prompt"

    if [ -n "$spec" ]; then
      printf '## Spec\n\n'
      if [ -f "$spec" ]; then
        sz="$(wc -c < "$spec" 2>/dev/null | tr -d ' ')"; case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
        if [ "$sz" -gt 65536 ]; then
          printf 'The spec is large (%s bytes), so it is not pasted here. Read it in full before you start: %s\n\n' "$sz" "$spec"
        else
          printf '(from %s)\n\n' "$spec"; cat "$spec"; printf '\n\n'
        fi
      else
        printf 'A spec was named but is missing at %s. Say so in your result rather than guessing what it contained.\n\n' "$spec"
      fi
    fi

    printf '## Done when\n\n'
    if [ "$shape" = ship ]; then
      printf -- '- You are in an isolated git worktree made for this task, on its own branch. Commit your finished work on that branch.\n'
      printf -- '- Leave no uncommitted changes to tracked files. Do not push, merge, rebase onto other branches, or open a pull request.\n'
      printf -- '- Never commit secrets (keys, tokens, .env files). A secret in the diff blocks the task.\n'
    else
      printf -- '- Do not change any files. Your final message IS the deliverable.\n'
      printf -- '- Make it complete and self-contained: the next workers see only what you write, not your session.\n'
    fi
    [ -n "$check" ] && printf -- '- This check must pass (exit code 0) from the top of the repository: `%s`\n' "$check"
    printf -- '- End with a short summary: what you did, what you found or changed, anything left open. It is handed to the tasks that depend on this one.\n\n'

    deps="$(printf '%s' "$t" | jq -r '(.deps // [])[]')"
    if [ -n "$deps" ]; then
      printf '## Inputs from finished work\n\n'
      printf 'These tasks finished before yours and feed into it. Build on them; do not redo them.\n\n'
      for d in $deps; do
        dt="$(_task_get "$plan" "$d" 2>/dev/null)" || { printf '### %s (missing)\nThis dependency could not be read.\n\n' "$d"; continue; }
        dtitle="$(printf '%s' "$dt" | jq -r '.title // ""')"
        dshape="$(printf '%s' "$dt" | jq -r '.shape // "scout"')"
        dres="$(printf '%s' "$dt" | jq -r '.result // ""')"
        dbr="$(printf '%s' "$dt" | jq -r '.branch // ""')"
        dhead="$(printf '%s' "$dt" | jq -r '.head_sha // ""')"
        djob="$(printf '%s' "$dt" | jq -r '.job // ""')"
        printf '### %s: %s (%s, %s)\n\n' "$d" "$dtitle" "$dshape" "$(printf '%s' "$dt" | jq -r .state)"
        [ -n "$dres" ] && printf 'Summary: %s\n\n' "$dres"
        if [ "$dshape" = ship ] && [ -n "$dbr" ]; then
          printf 'Code: branch `%s`%s. Its commits are not in your branch unless the plan merged them; read them with git if you need the exact change.\n\n' \
            "$dbr" "${dhead:+ at commit $dhead}"
        fi
        if out_path="$(_task_output_path "$plan" "$dt")"; then
          out_txt="$(_factory_trim 4000 < "$out_path")"
          if [ -n "$out_txt" ] && [ "$out_txt" != "$dres" ]; then
            printf 'Output:\n\n%s\n\n' "$out_txt"
          fi
          printf 'Full report: %s\n\n' "$out_path"
        elif [ -n "$djob" ]; then
          printf 'Full output: outsourcerer result %s\n\n' "$djob"
        fi
        dans="$(printf '%s' "$dt" | jq -r '.hold.answer // ""')"
        [ -n "$dans" ] && printf 'Captain decided on %s: %s\n\n' "$d" "$dans"
      done
    fi

    if [ -n "$ans" ]; then
      printf '## Decision from the captain\n\n'
      [ -n "$reason" ] && printf 'Question: %s\n\n' "$reason"
      printf '%s\n\n' "$ans"
    fi

    if [ "$attempts" -gt 0 ] 2>/dev/null && [ -n "$prev" ]; then
      printf '## Earlier attempt\n\nA previous attempt at this task did not finish. What went wrong: %s\nAvoid repeating it.\n\n' "$prev"
    fi
  } | _factory_write_file "$brief" || { echo "outsourcerer: could not write $brief" >&2; return 1; }
  printf '%s\n' "$brief"
}

# ---------------------------------------------------------------- dispatch

# _task_bg_launch <workdir> <cmd_bg args...> -> job id on stdout. The one seam between the factory
# and the existing bg machinery; tests override it so no real delegate runs. The caller has already
# exported OSRC_WORKTREE / OSRC_WORKTREE_BASE / OSRC_TASK_REF in this subshell.
_task_bg_launch() {
  local wd="$1"; shift
  cd "$wd" 2>/dev/null || { echo "outsourcerer: cannot enter $wd" >&2; return 1; }
  cmd_bg "$@"
}

# _task_claim_locked <plan> <tid> -> rc0 after moving a READY todo task to running (attempts+1,
# job cleared). Caller holds the lock. Prints the refusal reason on stderr otherwise.
_task_claim_locked() {
  local plan="$1" tid="$2" t st bl
  t="$(_task_get "$plan" "$tid")" || return 1
  st="$(printf '%s' "$t" | jq -r .state)"
  case "$st" in
    todo) ;;
    held) echo "outsourcerer: $tid is held for a decision ($(printf '%s' "$t" | jq -r '.hold.reason // ""')). Release it first: outsourcerer task release $tid --answer \"...\"" >&2; return 1 ;;
    running|verifying) echo "outsourcerer: $tid is already underway (job $(printf '%s' "$t" | jq -r '.job // "?"'))." >&2; return 1 ;;
    *) echo "outsourcerer: $tid is $st, not waiting to start. To run it again: outsourcerer task retry $tid" >&2; return 1 ;;
  esac
  bl="$(_task_list "$plan" | jq -r --arg id "$tid" "$_FACTORY_JQ_VIEW view | .[] | select(.id == \$id) | .blocked_by | map(\"\(.id) (\(.state))\") | join(\", \")")"
  if [ -n "$bl" ]; then
    echo "outsourcerer: $tid is not ready; it waits on $bl." >&2; return 1
  fi
  FACTORY_EVENT_NOTE="claimed for dispatch" _task_update_locked "$plan" "$tid" \
    'if .state != "todo" then error("not todo") else .state = "running" | .attempts = ((.attempts // 0) + 1) | .job = "" | .head_sha = "" | .evidence = "" end'
}

# _task_dispatch_fail <plan> <tid> <reason> -> a claimed task that cannot start is failed with the
# reason (so the captain sees it and a wake fires), never left stuck in running.
_task_dispatch_fail() {
  FACTORY_EVENT_NOTE="$3" _task_update "$1" "$2" '.state = "failed" | .result = $r' --arg r "$3" >/dev/null 2>&1 || true
  echo "outsourcerer: $2 could not start: $3" >&2
}

# _task_dispatch <plan> <tid> -> claim, brief, launch. Prints the job id; rc1 with a reason if the
# task is not ready, is held, is already claimed, or the launch failed (the task is then failed with
# the reason, so the captain sees it).
_task_dispatch() {
  local plan="$1" tid="$2" t pj repo base shape verb model provider brief prompt wd wt=0 base_sha="" jid out errf rc=0
  _factory_need_jq
  _plan_lock "$plan" || return 1
  _task_claim_locked "$plan" "$tid" || rc=1
  _plan_unlock "$plan"
  [ "$rc" -eq 0 ] || return 1

  t="$(_task_get "$plan" "$tid")" || return 1
  pj="$(jq -c . "$(_plan_dir "$plan")/plan.json" 2>/dev/null)" || pj='{}'
  repo="$(printf '%s' "$pj" | jq -r '.repo // ""')"; base="$(printf '%s' "$pj" | jq -r '.base_branch // ""')"
  shape="$(printf '%s' "$t" | jq -r '.shape // "scout"')"
  verb="$(printf '%s' "$t" | jq -r '.verb // ""')"; [ -n "$verb" ] || { [ "$shape" = ship ] && verb=edit || verb=run; }
  model="$(printf '%s' "$t" | jq -r '.model // ""')"
  provider="$(printf '%s' "$t" | jq -r '.provider // ""')"

  wd="$PWD"
  if [ -n "$repo" ]; then
    if ! git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
      _task_dispatch_fail "$plan" "$tid" "the plan's repo $repo is not a git repository any more"; return 1
    fi
    wd="$repo"
  fi
  if [ "$shape" = ship ]; then
    if [ -z "$repo" ]; then
      _task_dispatch_fail "$plan" "$tid" "ship tasks change code in their own git worktree, and this plan has no repo. Make the plan with --repo <path>"; return 1
    fi
    wt=1
    base_sha=""
    [ -n "$base" ] && base_sha="$(git -C "$repo" rev-parse --verify -q "$base^{commit}" 2>/dev/null)"
    [ -n "$base_sha" ] || base_sha="$(git -C "$repo" rev-parse --verify -q "HEAD^{commit}" 2>/dev/null)"
    [ -n "$base_sha" ] || { _task_dispatch_fail "$plan" "$tid" "cannot find the base commit in $repo"; return 1; }
  fi

  brief="$(_task_brief "$plan" "$tid")" || { _task_dispatch_fail "$plan" "$tid" "could not write the brief"; return 1; }
  prompt="$(cat "$brief")"

  local -a args=()
  [ -n "$provider" ] && args+=(--provider "$provider")
  args+=("$verb")
  [ -n "$model" ] && args+=(-m "$model")
  args+=("$prompt")

  errf="$(_task_dir "$plan" "$tid")/launch.log"
  out="$( export OSRC_WORKTREE="$wt" OSRC_TASK_REF="$plan/$tid"
          if [ "$wt" = 1 ]; then export OSRC_WORKTREE_BASE="$base_sha"; else unset OSRC_WORKTREE_BASE; fi
          _task_bg_launch "$wd" "${args[@]}" 2>"$errf" )" || rc=$?
  jid="$(printf '%s\n' "$out" | grep -E '^[0-9]{8}-[0-9]{6}-[0-9A-Za-z]+$' | tail -n 1)"
  if [ "$rc" -ne 0 ] || [ -z "$jid" ]; then
    [ -s "$errf" ] && grep -a -m 3 -E 'ERROR|refus|cannot|could not' "$errf" >&2
    _task_dispatch_fail "$plan" "$tid" "the worker did not launch (details: $errf)"
    return 1
  fi
  [ -d "$OSRC_JOBS/$jid" ] && printf '%s/%s\n' "$plan" "$tid" > "$OSRC_JOBS/$jid/task_ref" 2>/dev/null
  local wtp="" br=""
  if [ "$wt" = 1 ]; then wtp="$repo/.outsourcerer/worktrees/$jid"; br="outsourcerer/$jid"; fi
  FACTORY_EVENT_NOTE="job $jid" _task_update "$plan" "$tid" \
    '.job = $j | .jobs = ((.jobs // []) + [$j]) | .worktree = $w | .branch = $b | .base_sha = $s' \
    --arg j "$jid" --arg w "$wtp" --arg b "$br" --arg s "$base_sha" || return 1
  _task_event_full "$plan" "$tid" dispatched "" "" "job $jid" || true
  printf '%s\n' "$jid"
}

# ---------------------------------------------------------------- done fallback (when track C is absent)

# _task_job_status <job> -> the job's status word ("" when unknown).
_task_job_status() {
  [ -n "${1:-}" ] || return 0
  head -n 1 "$OSRC_JOBS/$1/status" 2>/dev/null | tr -d '\r\n '
}

# _task_done_fallback <plan> <tid> -> rc0 when the job ended successfully with a non-empty result.
# Used only when factory-land.sh (the full done contract) is not loaded.
_task_done_fallback() {
  local plan="$1" tid="$2" t job st
  t="$(_task_get "$plan" "$tid")" || return 1
  job="$(printf '%s' "$t" | jq -r '.job // ""')"
  [ -n "$job" ] || { echo "no worker job is attached to $tid"; return 1; }
  st="$(_task_job_status "$job")"
  case "$st" in
    done|'done?') ;;
    running|launching|'') echo "job $job is still ${st:-starting}"; return 1 ;;
    *) echo "job $job ended as $st"; return 1 ;;
  esac
  [ -s "$OSRC_JOBS/$job/last.txt" ] || { echo "job $job finished but left no result"; return 1; }
  echo "job $job finished with a result (basic check only: the full done contract is not installed)"
}

# ---------------------------------------------------------------- CLI: plan

cmd_plan() {
  _factory_need_jq
  local sub="${1:-ls}"; [ $# -gt 0 ] && shift
  case "$sub" in
    new)  _plan_cli_new "$@" ;;
    ls|list) _plan_cli_ls "$@" ;;
    show) _plan_cli_show "$@" ;;
    use)  _plan_cli_use "$@" ;;
    rm|remove|delete) _plan_cli_rm "$@" ;;
    -h|--help|help) _plan_cli_help ;;
    run)
      if type cmd_plan_run >/dev/null 2>&1; then cmd_plan_run "$@"
      else die "plan run needs factory-flow.sh next to outsourcerer.sh, and it is not installed."; fi ;;
    *)
      case "$sub" in *[!a-z_]*) ;; *)
        if type "cmd_plan_$sub" >/dev/null 2>&1; then "cmd_plan_$sub" "$@"; return $?; fi ;;
      esac
      die "unknown plan command '$sub'. Try: plan new|ls|show|use|rm|run" ;;
  esac
}

_plan_cli_help() {
  cat <<'EOF'
outsourcerer plan new <name> [--goal "..."] [--repo <path> | --no-repo] [--base <branch>] [--no-use]
outsourcerer plan ls
outsourcerer plan show [name]
outsourcerer plan use <name>
outsourcerer plan rm <name> [--force]
outsourcerer plan run [name] ...        (needs factory-flow.sh)
EOF
}

_plan_cli_new() {
  local name="" goal="" repo="" repo_set=0 base="" use=1 pd now top
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) goal="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; repo_set=1; shift 2 ;;
      --no-repo) repo=""; repo_set=2; shift ;;
      --base) base="${2:-}"; shift 2 ;;
      --no-use) use=0; shift ;;
      -*) die "plan new: unknown option '$1'" ;;
      *) [ -z "$name" ] && name="$1" || goal="${goal:-$1}"; shift ;;
    esac
  done
  [ -n "$name" ] || die "plan new needs a name, e.g. outsourcerer plan new checkout-v2 --goal \"ship the new checkout\""
  _plan_name_ok "$name" || die "'$name' is not a valid plan name (letters, digits, dot, dash, underscore; up to 64; not 'current')."
  if [ "$repo_set" = 1 ]; then
    [ -d "$repo" ] || die "plan new: $repo is not a folder."
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "plan new: $repo is not inside a git repository."
    repo="$(cd "$top" && pwd -P)"
  elif [ "$repo_set" = 0 ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" && repo="$(cd "$top" && pwd -P)" || repo=""
  fi
  if [ -n "$repo" ] && [ -z "$base" ]; then
    base="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)" || base=""
  fi
  if [ -n "$repo" ] && [ -n "$base" ] && ! git -C "$repo" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    die "plan new: branch '$base' does not exist in $repo."
  fi
  _mkdir_private "$(_plans_root)" || die "cannot create $(_plans_root)"
  pd="$(_plan_dir "$name")"
  mkdir "$pd" 2>/dev/null || die "a plan named '$name' already exists. Pick another name, or see it with: outsourcerer plan show $name"
  mkdir -p "$pd/tasks"
  now="$(_factory_now)"
  _factory_write_json "$pd/plan.json" "$(jq -cn --arg n "$name" --arg g "$goal" --arg r "$repo" --arg b "$base" --arg now "$now" \
    '{schema:1,name:$n,goal:$g,repo:$r,base_branch:$b,created:$now,updated:$now}')" || die "could not save $pd/plan.json"
  : > "$pd/events.jsonl"
  _task_event_full "$name" "" plan-created "" "" "$goal" || true
  [ "$use" = 1 ] && printf '%s\n' "$name" | _factory_write_file "$(_plans_root)/current"
  echo "plan '$name' created${repo:+ for $repo}${base:+ (base branch $base)}$( [ "$use" = 1 ] && echo '; it is now the current plan')."
  [ -z "$repo" ] && echo "No repo is set, so this plan can hold scout tasks only. To build code, make it inside a git repo or pass --repo <path>."
  echo "Next: outsourcerer task add \"<what to do>\" [--shape ship|scout] [--deps t1,t2]"
}

_plan_cli_ls() {
  local root d n cur="" pj counts
  root="$(_plans_root)"
  cur="$(_plan_current 2>/dev/null)" || cur=""
  local any=0
  for d in "$root"/*/; do
    [ -f "$d/plan.json" ] || continue
    n="$(basename "$d")"; any=1
    pj="$(jq -c . "$d/plan.json" 2>/dev/null)" || pj='{"goal":"(plan.json is damaged)"}'
    counts="$(_task_view "$n" 2>/dev/null | jq -r 'group_by(.derived) | map("\(length) \(.[0].derived)") | join(", ")')"
    printf '%s %s  %s\n' "$( [ "$n" = "$cur" ] && echo '*' || echo ' ')" "$n" "$(printf '%s' "$pj" | jq -r '.goal // ""')"
    printf '      %s\n' "${counts:-no tasks yet}"
  done
  [ "$any" = 1 ] || echo "No plans yet. Make one with: outsourcerer plan new <name> --goal \"...\""
}

_plan_cli_use() {
  local p; [ -n "${1:-}" ] || die "plan use needs a plan name. See them with: outsourcerer plan ls"; p="$(_plan_resolve "$1")" || exit 1
  printf '%s\n' "$p" | _factory_write_file "$(_plans_root)/current" || die "could not save the current plan"
  echo "current plan: $p"
}

_plan_cli_rm() {
  local name="" force=0 pd running
  while [ $# -gt 0 ]; do
    case "$1" in --force|-f) force=1; shift ;; -*) die "plan rm: unknown option '$1'" ;; *) name="$1"; shift ;; esac
  done
  [ -n "$name" ] || die "plan rm needs a plan name."
  name="$(_plan_resolve "$name")" || exit 1
  pd="$(_plan_dir "$name")"
  running="$(_task_list "$name" | jq -r 'map(select(.state == "running" or .state == "verifying")) | map(.id) | join(", ")')"
  if [ -n "$running" ] && [ "$force" != 1 ]; then
    die "plan '$name' still has work underway ($running). Cancel those tasks first, or pass --force to remove the plan anyway (their jobs keep running)."
  fi
  case "$pd" in "$(_plans_root)"/?*) ;; *) die "refusing to remove $pd" ;; esac
  rm -rf "$pd" || die "could not remove $pd"
  [ "$(_plan_current 2>/dev/null)" = "$name" ] && rm -f "$(_plans_root)/current"
  echo "plan '$name' removed. Its git worktrees and branches, if any, are untouched (outsourcerer cleanup <job> removes a worktree)."
}

# _plan_cli_show [plan] -> the four-bucket view + a compact dependency listing.
_plan_cli_show() {
  local plan="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) json=1; shift ;; --plan) plan="${2:-}"; shift 2 ;; -*) die "plan show: unknown option '$1'" ;; *) plan="$1"; shift ;; esac
  done
  plan="$(_plan_resolve "$plan")" || exit 1
  local pj view
  pj="$(jq -c . "$(_plan_dir "$plan")/plan.json" 2>/dev/null)" || pj="{\"name\":\"$plan\",\"goal\":\"(plan.json is damaged)\"}"
  view="$(_task_view "$plan")"
  if [ "$json" = 1 ]; then
    jq -n --argjson p "$pj" --argjson t "$view" '{plan:$p,tasks:$t}'; return 0
  fi
  printf '%s' "$view" | jq -r --argjson p "$pj" '
    def line(s): "  - \(.id) [\(s)] \(.title)";
    def first(s): (s // "" | tostring | split("\n")[0] | if length > 100 then .[0:100] + "..." else . end);
    def bucket(name; rows): [name] + (if (rows | length) == 0 then ["  (nothing)"] else rows end);
    . as $all
    | (reduce $all[] as $t ({}; .[$t.id] = $t)) as $by
    | ["Plan \($p.name // "?"): \($p.goal // "")"]
      + (if ($p.repo // "") != "" then ["Repo: \($p.repo)\(if ($p.base_branch // "") != "" then " (base \($p.base_branch))" else "" end)"] else [] end)
      + [""]
      + bucket("Captain'"'"'s Call";
          [ $all[] | select(.state == "held")
            | line("held") + " - needs a decision: \(first(.hold.reason))" + (if (.hold.until // "") != "" then " (by \(.hold.until))" else "" end)
              + "\n      answer with: outsourcerer task release \(.id) --answer \"...\"" ]
          + [ $all[] | select(.state == "failed")
            | line("failed") + (if (.result // "") != "" then " - \(first(.result))" else "" end)
              + "\n      retry with: outsourcerer task retry \(.id)   or drop it: outsourcerer task cancel \(.id)" ])
      + [""]
      + bucket("Done";
          [ $all[] | select(.state == "done" or .state == "canceled")
            | line(if .state == "done" then (if .landed == true then "landed" else "done" end) else "canceled" end)
              + (if (.result // "") != "" then " - \(first(.result))" else "" end) ])
      + [""]
      + bucket("Underway";
          [ $all[] | select(.state == "running" or .state == "verifying")
            | line(.state) + (if (.job // "") != "" then " - job \(.job)" else "" end)
              + (if (.model // "") != "" then " on \(.model)" else "" end) ])
      + [""]
      + bucket("Next";
          [ $all[] | select(.derived == "ready") | line("ready") ]
          + [ $all[] | select(.derived == "blocked")
            | line("blocked") + " - waiting on "
              + (.blocked_by | map(.id + " (" + .state + ")"
                  + (if .state == "failed" or .state == "canceled" then ", needs the captain" elif .state == "held" then ", held for a decision" else "" end))
                 | join(", ")) ])
      + (if ([$all[] | select((.deps // []) | length > 0)] | length) > 0 then
           ["", "Dependencies"] + [ $all[] | select((.deps // []) | length > 0) | "  \(.id) <- \(.deps | join(", "))" ]
         else [] end)
    | .[]'
}

# ---------------------------------------------------------------- CLI: task

cmd_task() {
  _factory_need_jq
  local sub="${1:-ls}"; [ $# -gt 0 ] && shift
  case "$sub" in
    add|new)  _task_cli_add "$@" ;;
    ls|list)  _task_cli_ls "$@" ;;
    show)     _task_cli_show "$@" ;;
    ready)    _task_cli_ready "$@" ;;
    start|dispatch) _task_cli_start "$@" ;;
    hold)     _task_cli_hold "$@" ;;
    release)  _task_cli_release "$@" ;;
    done)     _task_cli_done "$@" ;;
    fail)     _task_cli_fail "$@" ;;
    cancel)   _task_cli_cancel "$@" ;;
    retry)    _task_cli_retry "$@" ;;
    brief)    _task_cli_brief "$@" ;;
    -h|--help|help) _task_cli_help ;;
    *) die "unknown task command '$sub'. Try: task add|ls|show|ready|start|hold|release|done|fail|cancel|retry" ;;
  esac
}

_task_cli_help() {
  cat <<'EOF'
outsourcerer task add "<title>" [--prompt "..." | --prompt-file f] [--shape ship|scout] [--deps t1,t2]
        [--spec file] [--check "cmd"] [--verb run|research|edit|yolo] [-m model] [--provider p]
        [--deliver local|branch|pr] [--retries N] [--hold "question"] [--plan p]
outsourcerer task ls [--state s] [--plan p]          outsourcerer task show <tid> [--json] [--plan p]
outsourcerer task ready [--plan p]                   outsourcerer task start <tid> [--plan p]
outsourcerer task hold <tid> --reason "..." [--until "..."]
outsourcerer task release <tid> --answer "..." [--done]
outsourcerer task done <tid> [--result "..."] [--force]
outsourcerer task fail <tid> [--reason "..."]        outsourcerer task cancel <tid>
outsourcerer task retry <tid>                        outsourcerer task brief <tid>
EOF
}

# _task_cli_args: pull --plan out of the argv; leaves the rest in _TASK_ARGV and the plan in _TASK_PLAN.
_TASK_ARGV=(); _TASK_PLAN=""
_task_cli_args() {
  _TASK_ARGV=(); _TASK_PLAN=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) [ -n "${2:-}" ] || die "--plan needs a plan name"; _TASK_PLAN="$2"; shift 2 ;;
      --plan=*) _TASK_PLAN="${1#--plan=}"; shift ;;
      *) _TASK_ARGV+=("$1"); shift ;;
    esac
  done
  _TASK_PLAN="$(_plan_resolve "$_TASK_PLAN")" || exit 1
}

_task_cli_add() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local plan="$_TASK_PLAN" title="" prompt="" shape="" deps="" spec="" check="" verb="" model="" provider=""
  local deliver="local" retries=1 hold="" flow="" stage="" fields tid
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) prompt="${2:-}"; shift 2 ;;
      --prompt-file) [ -f "${2:-}" ] || die "task add: no such prompt file '${2:-}'"; prompt="$(cat "$2")"; shift 2 ;;
      --shape) shape="${2:-}"; shift 2 ;;
      --deps|--after) deps="${2:-}"; shift 2 ;;
      --spec) spec="${2:-}"; shift 2 ;;
      --check) check="${2:-}"; shift 2 ;;
      --verb) verb="${2:-}"; shift 2 ;;
      -m|--model) model="${2:-}"; shift 2 ;;
      --provider) provider="${2:-}"; shift 2 ;;
      --deliver) deliver="${2:-}"; shift 2 ;;
      --retries) retries="${2:-}"; shift 2 ;;
      --hold) hold="${2:-}"; shift 2 ;;
      --flow) flow="${2:-}"; shift 2 ;;
      --stage) stage="${2:-}"; shift 2 ;;
      -*) die "task add: unknown option '$1'" ;;
      *) [ -z "$title" ] && title="$1" || die "task add: give one title (quote it). Extra text: '$1'"; shift ;;
    esac
  done
  [ -n "$title" ] || die "task add needs a title, e.g. outsourcerer task add \"map the auth flow\" --shape scout"
  case "$verb" in ''|run|research|edit|yolo) ;; *) die "task add: --verb must be run, research, edit or yolo." ;; esac
  if [ -z "$shape" ]; then case "$verb" in edit|yolo) shape=ship ;; *) shape=scout ;; esac; fi
  case "$shape" in ship|scout) ;; *) die "task add: --shape must be ship (changes code) or scout (investigates)." ;; esac
  case "$deliver" in local|branch|pr) ;; *) die "task add: --deliver must be local, branch or pr." ;; esac
  case "$retries" in ''|*[!0-9]*) die "task add: --retries must be a whole number." ;; esac
  if [ -n "$spec" ]; then
    [ -f "$spec" ] || die "task add: the spec file '$spec' does not exist."
    spec="$(cd "$(dirname "$spec")" && pwd -P)/$(basename "$spec")"
  fi
  local d; deps="$(printf '%s' "$deps" | tr ', ' '\n\n' | sed '/^$/d')"
  for d in $deps; do _task_id_ok "$d" || die "task add: '$d' is not a task id (they look like t1, t2)."; done
  fields="$(jq -cn --arg title "$title" --arg prompt "$prompt" --arg shape "$shape" --arg deps "$deps" --arg spec "$spec" \
    --arg check "$check" --arg verb "$verb" --arg model "$model" --arg provider "$provider" --arg deliver "$deliver" \
    --argjson retries "$retries" --arg hold "$hold" --arg flow "$flow" --arg stage "$stage" '
    {title:$title,prompt:$prompt,shape:$shape,deps:($deps | split("\n") | map(select(. != "")) | unique),
     spec:$spec,check:$check,verb:$verb,model:$model,provider:$provider,deliver:$deliver,retries:$retries,
     flow:{name:$flow,stage:$stage}}
    + (if $hold != "" then {state:"held",hold:{reason:$hold,until:"",answer:""}} else {} end)')"
  tid="$(_task_new "$plan" "$fields")" || exit 1
  printf '%s\n' "$tid"
  echo "added $tid to plan '$plan' ($shape)${deps:+, after $(printf '%s' "$deps" | tr '\n' ' ' | sed 's/ $//;s/ /, /g')}${hold:+, held for a decision}." >&2
}

_task_cli_ls() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local st="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in --state) st="${2:-}"; shift 2 ;; --json) json=1; shift ;; *) die "task ls: unknown option '$1'" ;; esac
  done
  local view; view="$(_task_view "$_TASK_PLAN")"
  [ "$json" = 1 ] && { printf '%s\n' "$view" | jq --arg s "$st" 'map(select($s == "" or .state == $s or .derived == $s))'; return 0; }
  printf '%s' "$view" | jq -r --arg s "$st" '
    map(select($s == "" or .state == $s or .derived == $s))
    | if length == 0 then "No tasks\(if $s != "" then " in state \($s)" else "" end). Add one with: outsourcerer task add \"...\""
      else (["ID", "STATE", "SHAPE", "AFTER", "JOB", "TITLE"] | @tsv),
           (.[] | [.id, .derived, .shape, ((.deps // []) | join(",") | if . == "" then "-" else . end),
                   (if (.job // "") == "" then "-" else .job end), .title] | @tsv)
      end' | { if have column; then column -t -s "$(printf '\t')"; else cat; fi; }
}

_task_one_arg() {   # <usage> -> sets _TASK_TID from the first positional in _TASK_ARGV
  _TASK_TID="${_TASK_ARGV[0]:-}"
  [ -n "$_TASK_TID" ] || die "$1"
  _task_id_ok "$_TASK_TID" || die "'$_TASK_TID' is not a task id (they look like t1, t2)."
}

_task_cli_show() {
  _task_cli_args "$@"
  local json=0 a rest=()
  for a in ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}; do [ "$a" = "--json" ] && json=1 || rest+=("$a"); done
  _TASK_ARGV=(${rest[@]+"${rest[@]}"})
  _task_one_arg "task show needs a task id, e.g. outsourcerer task show t3"
  local t; t="$(_task_get "$_TASK_PLAN" "$_TASK_TID")" || exit 1
  [ "$json" = 1 ] && { printf '%s\n' "$t" | jq .; return 0; }
  local derived; derived="$(_task_view "$_TASK_PLAN" | jq -r --arg id "$_TASK_TID" '.[] | select(.id == $id) | .derived + (if (.blocked_by|length) > 0 then " (waiting on " + (.blocked_by | map(.id + " " + .state) | join(", ")) + ")" else "" end)')"
  printf '%s' "$t" | jq -r --arg d "$derived" --arg bd "$(_task_dir "$_TASK_PLAN" "$_TASK_TID")" '
    "\(.plan)/\(.id): \(.title)",
    "  state:    \($d)",
    "  shape:    \(.shape)   verb: \(.verb)\(if .model != "" then "   model: " + .model else "" end)\(if .provider != "" then "   provider: " + .provider else "" end)",
    (if (.deps|length) > 0 then "  after:    \(.deps | join(", "))" else empty end),
    (if .check != "" then "  check:    \(.check)" else empty end),
    (if .spec != "" then "  spec:     \(.spec)" else empty end),
    "  attempts: \(.attempts) of \((.retries // 0) + 1)",
    (if .job != "" then "  job:      \(.job)   (all: \(.jobs | join(", ")))" else empty end),
    (if .branch != "" then "  branch:   \(.branch) at \(.worktree)\(if .base_sha != "" then " (base " + .base_sha[0:12] + ")" else "" end)" else empty end),
    (if .hold.reason != "" then "  question: \(.hold.reason)\(if .hold.until != "" then " (by " + .hold.until + ")" else "" end)" else empty end),
    (if .hold.answer != "" then "  answer:   \(.hold.answer)" else empty end),
    (if .result != "" then "  result:   \(.result)" else empty end),
    (if .evidence != "" then "  evidence: \(.evidence)" else empty end),
    "  files:    \($bd)/",
    "  prompt:",
    (.prompt | split("\n") | .[0:12][] | "    " + .)'
  local ev; ev="$(_plan_dir "$_TASK_PLAN")/events.jsonl"
  if [ -s "$ev" ]; then
    echo "  recent events:"
    jq -r --arg id "$_TASK_TID" 'select(.task == $id) | "    \(.ts) \(.event)\(if .from != "" or .to != "" then " " + .from + " -> " + .to else "" end)\(if .note != "" then " (" + .note + ")" else "" end)"' "$ev" 2>/dev/null | tail -n 8
  fi
}

_task_cli_ready() {
  _task_cli_args "$@"
  local ids; ids="$(_task_ready "$_TASK_PLAN")"
  [ -n "$ids" ] || { echo "Nothing is ready in plan '$_TASK_PLAN'. See why with: outsourcerer plan show" >&2; return 0; }
  _task_list "$_TASK_PLAN" | jq -r --arg ids "$ids" '($ids | split("\n")) as $o | INDEX(.id) as $by | $o[] | "\(.)\t\($by[.].title)"'
}

_task_cli_brief() {
  _task_cli_args "$@"
  _task_one_arg "task brief needs a task id"
  local p; p="$(_task_brief "$_TASK_PLAN" "$_TASK_TID")" || exit 1
  cat "$p"; echo; echo "(saved at $p)" >&2
}

_task_cli_start() {
  _task_cli_args "$@"
  _task_one_arg "task start needs a task id, e.g. outsourcerer task start t2"
  local jid; jid="$(_task_dispatch "$_TASK_PLAN" "$_TASK_TID")" || exit 1
  printf '%s\n' "$jid"
  echo "$_TASK_TID started as job $jid. Its brief: $(_task_dir "$_TASK_PLAN" "$_TASK_TID")/brief.md. Watch it: outsourcerer watch $jid" >&2
}

_task_cli_hold() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" reason="" until=""
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="${2:-}"; shift 2 ;; --until) until="${2:-}"; shift 2 ;; -*) die "task hold: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task hold needs a task id, e.g. outsourcerer task hold t3 --reason \"pick A or B\""
  [ -n "$reason" ] || die "task hold needs --reason \"<the question for the captain>\"."
  FACTORY_EVENT_NOTE="$reason" _task_update "$_TASK_PLAN" "$tid" \
    'if (.state == "todo" or .state == "failed" or .state == "verifying" or .state == "held") | not
       then error("bad state") else .state = "held" | .hold = {reason:$r, until:$u, answer:""} end' \
    --arg r "$reason" --arg u "$until" \
    || die "$tid can be held only while it waits, is being checked, or has failed. If it is running, cancel it first."
  echo "$tid is held for a decision ($reason). Answer with: outsourcerer task release $tid --answer \"...\""
}

_task_cli_release() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" answer="" mkdone=0
  while [ $# -gt 0 ]; do
    case "$1" in --answer) answer="${2:-}"; shift 2 ;; --done) mkdone=1; shift ;; -*) die "task release: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task release needs a task id, e.g. outsourcerer task release t3 --answer \"go with B\""
  [ -n "$answer" ] || die "task release needs --answer \"<your decision>\". It is handed to this task and the ones after it."
  if [ "$mkdone" = 1 ]; then
    FACTORY_EVENT_NOTE="$answer" _task_update "$_TASK_PLAN" "$tid" \
      'if .state != "held" then error("not held") else .state = "done" | .hold.answer = $a | .result = $a end' --arg a "$answer" \
      || die "$tid is not held, so there is nothing to release."
    echo "$tid is done with your decision; the tasks after it now see it."
  else
    FACTORY_EVENT_NOTE="$answer" _task_update "$_TASK_PLAN" "$tid" \
      'if .state != "held" then error("not held") else .state = "todo" | .hold.answer = $a end' --arg a "$answer" \
      || die "$tid is not held, so there is nothing to release."
    echo "$tid released with your answer; it goes back in line to run."
  fi
}

# _task_finish_from_output <plan> <tid> -> after a passed done check: copy a scout's output to
# report.md and fill .result with a short summary when nothing set one.
_task_finish_from_output() {
  local plan="$1" tid="$2" t job shape rep sum
  t="$(_task_get "$plan" "$tid")" || return 0
  job="$(printf '%s' "$t" | jq -r '.job // ""')"; shape="$(printf '%s' "$t" | jq -r '.shape // ""')"
  rep="$(_task_dir "$plan" "$tid")/report.md"
  if [ "$shape" = scout ] && [ ! -s "$rep" ] && [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ]; then
    _factory_write_file "$rep" < "$OSRC_JOBS/$job/last.txt" || true
  fi
  if [ -z "$(printf '%s' "$t" | jq -r '.result // ""')" ]; then
    if [ -s "$rep" ]; then sum="$(_factory_trim 600 < "$rep")"
    elif [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ]; then sum="$(_factory_trim 600 < "$OSRC_JOBS/$job/last.txt")"
    else sum=""; fi
    [ -n "$sum" ] && _task_update "$plan" "$tid" '.result = $s' --arg s "$sum" || true
  fi
}

_task_cli_done() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" result="" force=0 why rc=0 prev
  while [ $# -gt 0 ]; do
    case "$1" in --result) result="${2:-}"; shift 2 ;; --force) force=1; shift ;; -*) die "task done: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task done needs a task id, e.g. outsourcerer task done t2"
  local t; t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  prev="$(printf '%s' "$t" | jq -r .state)"
  case "$prev" in
    done) echo "$tid is already done."; return 0 ;;
    canceled) die "$tid was canceled. Run it again with: outsourcerer task retry $tid" ;;
  esac
  if [ "$force" = 1 ]; then
    FACTORY_EVENT_NOTE="marked done by hand${result:+: $result}" _task_update "$_TASK_PLAN" "$tid" \
      '.state = "done" | (if $r != "" then .result = $r else . end)' --arg r "$result" || exit 1
    echo "$tid marked done by hand (no check was run)."
    return 0
  fi
  case "$prev" in running|verifying|failed) ;; *) die "$tid has not run yet ($prev). Start it with: outsourcerer task start $tid  (or mark it done by hand with --force)" ;; esac
  _task_update "$_TASK_PLAN" "$tid" '.state = "verifying"' >/dev/null || exit 1
  if type _factory_done_check >/dev/null 2>&1; then
    why="$(_factory_done_check "$_TASK_PLAN" "$tid")" || rc=$?
  else
    why="$(_task_done_fallback "$_TASK_PLAN" "$tid")" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    [ -n "$result" ] && _task_update "$_TASK_PLAN" "$tid" '.result = $r' --arg r "$result" >/dev/null
    _task_finish_from_output "$_TASK_PLAN" "$tid"
    FACTORY_EVENT_NOTE="$why" _task_update "$_TASK_PLAN" "$tid" '.state = "done"' || exit 1
    echo "$tid is done: $why"
    return 0
  fi
  FACTORY_EVENT_NOTE="not done: $why" _task_update "$_TASK_PLAN" "$tid" '.state = $p' --arg p "$prev" >/dev/null 2>&1 || true
  echo "$tid is not done: $why" >&2
  echo "If the work is good anyway: outsourcerer task done $tid --force. If it is bad: outsourcerer task fail $tid --reason \"...\"" >&2
  return 1
}

# _task_stop_job <job> -> best-effort stop of a live worker job (cancel/fail of a running task).
_task_stop_job() {
  local job="${1:-}" st
  [ -n "$job" ] || return 0
  st="$(_task_job_status "$job")"
  case "$st" in running|launching)
    if type cmd_cancel >/dev/null 2>&1; then ( cmd_cancel "$job" ) >/dev/null 2>&1 || true; echo "stopped job $job." ; fi ;;
  esac
}

_task_cli_fail() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="${2:-}"; shift 2 ;; -*) die "task fail: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task fail needs a task id, e.g. outsourcerer task fail t2 --reason \"tests still red\""
  local t; t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  [ -n "$reason" ] || reason="marked failed by hand"
  FACTORY_EVENT_NOTE="$reason" _task_update "$_TASK_PLAN" "$tid" \
    'if (.state == "done" or .state == "canceled") then error("final") else .state = "failed" | .result = $r end' --arg r "$reason" \
    || die "$tid is already finished ($(printf '%s' "$t" | jq -r .state)); nothing to fail."
  _task_stop_job "$(printf '%s' "$t" | jq -r '.job // ""')"
  echo "$tid failed: $reason. Tasks after it stay blocked until you retry or cancel it."
}

_task_cli_cancel() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="${1:-}"
  _task_id_ok "$tid" || die "task cancel needs a task id, e.g. outsourcerer task cancel t2"
  local t; t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  FACTORY_EVENT_NOTE="canceled by hand" _task_update "$_TASK_PLAN" "$tid" \
    'if .state == "done" then error("done") else .state = "canceled" end' \
    || die "$tid is already done; there is nothing to cancel."
  _task_stop_job "$(printf '%s' "$t" | jq -r '.job // ""')"
  echo "$tid canceled. Tasks after it stay blocked until you retry it or cancel them too."
}

_task_cli_retry() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="${1:-}"
  _task_id_ok "$tid" || die "task retry needs a task id, e.g. outsourcerer task retry t2"
  FACTORY_EVENT_NOTE="retry by hand" _task_update "$_TASK_PLAN" "$tid" \
    'if (.state == "failed" or .state == "canceled") | not then error("not retryable")
     else .state = "todo" | .job = "" | .worktree = "" | .branch = "" | .base_sha = "" | .head_sha = "" | .evidence = "" end' \
    || die "only a failed or canceled task can be retried; $tid is $(_task_get "$_TASK_PLAN" "$tid" 2>/dev/null | jq -r '.state // "unknown"')."
  echo "$tid is back in line. It runs when its dependencies are done (start it now with: outsourcerer task start $tid)."
}
