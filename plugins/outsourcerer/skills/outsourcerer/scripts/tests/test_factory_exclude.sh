#!/usr/bin/env bash
# test_factory_exclude.sh — issue #45: a persistent model exclude list.
# `exclude add|rm|ls|clear|check`, robust family matching, refusal of an explicit -m on every verb,
# and every automatic choice skipping excluded models. Fake CLIs only: no real model is ever called.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-factory-exclude.XXXXXX")"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Fake model CLIs: each records that it was invoked. A refusal must leave this log empty.
FB="$TMP/fake-bin"; mkdir -p "$FB"; CALLS="$TMP/calls.log"
for c in claude codex devin agy gemini droid cursor-agent oz cline hermes; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\necho PONG\nexit 0\n' "$c" "$CALLS" > "$FB/$c"; chmod +x "$FB/$c"
done
export PATH="$FB:$PATH"
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
export OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_NO_ADVISE=1 OSRC_BRIEF_NO_HEAL=1 OSRC_DOCTOR_OFFLINE=1
unset OSRC_EXCLUDE_MODELS OSRC_MODEL_DENYLIST OSRC_SECOND_OPINION_MODELS OSRC_SECOND_OPINION_PREMIUM OSRC_ESCALATE_LADDER OR_OFFLOAD_CHAIN 2>/dev/null || true

run() { bash "$SRC" "$@"; }
# lib <snippet>: source the script (main suppressed) and run a snippet in that shell.
lib() { OSRC_SOURCED=1 bash -c 'src="$1"; code="$2"; set --; . "$src" >/dev/null 2>&1; eval "$code"' bash "$SRC" "$1"; }

# ---------------------------------------------------------------- CLI: add / ls / rm / clear
out="$(run exclude ls 2>&1)"
printf '%s' "$out" | grep -q 'no models excluded' && ok "exclude ls on an empty list says so" || bad "empty ls: $out"
out="$(run exclude add Fable 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qx 'fable' "$OSRC_HOME/exclude" && ok "exclude add stores the entry lowercased in \$OSRC_HOME/exclude" || bad "add: rc=$rc $out"
out="$(run exclude add fable 2>&1)"
[ "$(grep -c . "$OSRC_HOME/exclude")" = 1 ] && printf '%s' "$out" | grep -q 'already excluded' && ok "exclude add is idempotent" || bad "duplicate add: $out"
out="$(run exclude add '5' 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no letters' && ok "an entry with no letters is refused (would exclude half the catalog)" || bad "digit entry accepted: $out"
out="$(run exclude add 'fa;ble' 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "an entry with shell metacharacters is refused" || bad "metachar entry accepted: $out"
out="$(OSRC_EXCLUDE_MODELS="glm, Haiku" run exclude ls 2>&1)"
printf '%s' "$out" | grep -q '^  fable$' && printf '%s' "$out" | grep -q 'haiku.*OSRC_EXCLUDE_MODELS' \
  && ok "exclude ls unions the saved list with OSRC_EXCLUDE_MODELS and labels the source" || bad "ls union: $out"
run exclude add opus >/dev/null 2>&1
out="$(run exclude rm OPUS 2>&1)"
grep -qx opus "$OSRC_HOME/exclude" && bad "rm left the entry: $out" || { grep -qx fable "$OSRC_HOME/exclude" && ok "exclude rm removes one entry (case-insensitive) and keeps the rest" || bad "rm dropped other entries"; }
out="$(OSRC_EXCLUDE_MODELS=sol run exclude rm sol 2>&1)"
printf '%s' "$out" | grep -q 'still excluded by the OSRC_EXCLUDE_MODELS' && ok "exclude rm warns when the env var still excludes it" || bad "rm env note: $out"
cp "$OSRC_HOME/exclude" "$TMP/exclude.bak"
out="$(run exclude clear 2>&1)"
[ ! -f "$OSRC_HOME/exclude" ] && ok "exclude clear removes the saved list" || bad "clear: $out"
cp "$TMP/exclude.bak" "$OSRC_HOME/exclude"
out="$(run exclude bogus 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'unknown action' && ok "unknown exclude action fails with the usage" || bad "bogus action: $out"

# ---------------------------------------------------------------- matcher
chk() { run exclude check "$1" >/dev/null 2>&1; }
allm=1
for m in fable FABLE Fable claude-fable-5 claude-fable-5-1 anthropic/claude-5-fable 'claude-fable-5-1[1m]'; do
  chk "$m" || { allm=0; bad "family 'fable' did not match $m"; }
done
[ "$allm" = 1 ] && ok "family entry 'fable' matches fable, claude-fable-5, claude-fable-5-1, anthropic/claude-5-fable, any case, [1m] suffix"
nonm=1
for m in opus sonnet haiku sol glm claude-opus-4-8 gpt-5.6-sol; do chk "$m" && { nonm=0; bad "fable entry wrongly matched $m"; }; done
[ "$nonm" = 1 ] && ok "family entry 'fable' leaves other models allowed"
OSRC_EXCLUDE_MODELS='gpt-5.6-*' bash "$SRC" exclude check sol >/dev/null 2>&1 && OSRC_EXCLUDE_MODELS='gpt-5.6-*' bash "$SRC" exclude check terra >/dev/null 2>&1 \
  && ! OSRC_EXCLUDE_MODELS='gpt-5.6-*' bash "$SRC" exclude check gpt-5.5 >/dev/null 2>&1 \
  && ok "a glob entry matches through alias resolution (sol -> gpt-5.6-sol) and stays precise" || bad "glob matching"
( export OSRC_HOME="$TMP/state2"; mkdir -p "$OSRC_HOME"
  OSRC_EXCLUDE_MODELS=claude-fable-5 bash "$SRC" exclude check claude-fable-5-1 >/dev/null 2>&1 \
    && ! OSRC_EXCLUDE_MODELS=claude-fable-5 bash "$SRC" exclude check claude-opus-5 >/dev/null 2>&1 ) \
  && ok "an exact id entry covers its point releases but not other families" || bad "exact id matching"
( export OSRC_HOME="$TMP/state2"
  OSRC_EXCLUDE_MODELS=glm bash "$SRC" exclude check z-ai/glm-5.2 >/dev/null 2>&1 \
    && OSRC_EXCLUDE_MODELS=sol bash "$SRC" exclude check gpt-5.6-sol >/dev/null 2>&1 \
    && ! OSRC_EXCLUDE_MODELS=5 bash "$SRC" exclude check glm-5.2 >/dev/null 2>&1 ) \
  && ok "alias entries match their resolved ids; a letterless env entry is ignored" || bad "alias/letterless matching"
r="$(lib '_exclude_active && echo active || echo idle' 2>/dev/null)"
r2="$(OSRC_HOME="$TMP/empty-state" OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; _exclude_active && echo active || echo idle; _model_excluded fable && echo hit || echo miss' bash "$SRC" 2>/dev/null | tr '\n' ' ')"
[ "$r" = active ] && [ "$r2" = "idle miss " ] && ok "no list -> nothing excluded (default routing untouched)" || bad "active/idle: '$r' '$r2'"

# ---------------------------------------------------------------- explicit -m refused on every verb
refused() { # <label> <cmd...>
  local label="$1"; shift; : > "$CALLS"
  local o rc; o="$("$@" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && printf '%s' "$o" | grep -q "you excluded" && printf '%s' "$o" | grep -q 'exclude rm fable' && [ ! -s "$CALLS" ]; then
    ok "$label: refused with one plain line naming the fix; no model CLI ran"
  else
    bad "$label: rc=$rc calls=$(cat "$CALLS" 2>/dev/null | head -2) out=$(printf '%s' "$o" | tail -3)"
  fi
}
refused "run -m fable"                       run run -m fable "hello"
refused "research -m claude-fable-5"         run research -m claude-fable-5 "hello"
refused "edit -m Claude-Fable-5-1"           run edit -m Claude-Fable-5-1 "hello"
refused "yolo -m fable"                      run yolo -m fable "hello"
refused "explore --provider cc -m fable"     run explore --provider cc -m fable "hello"
refused "bg run -m fable"                    run bg run -m fable "hello"
refused "bg -m fable (verb implied)"         run bg -m fable "hello"
refused "fanout -m fable"                    run fanout -m fable -- "a" "b"
refused "fanout --route task*=fable"         run fanout --route 'task*=fable' -- "a"
refused "loop verify -m fable"               run loop verify -m fable --check true "task"
refused "loop escalate -m fable"             run loop escalate -m fable --check true "task"
refused "loop escalate --ladder haiku,fable" run loop escalate --ladder haiku,fable --check true "task"
refused "second-opinion -m glm,fable"        run second-opinion -m glm,fable "question"
refused "continue -m fable"                  run continue -m fable "next"
if command -v tmux >/dev/null 2>&1; then
  refused "session start -m fable"           run --provider cc session start -m fable
  refused "session model fable"              run session model fable
else
  ok "session start/model: tmux absent here, refusal path covered by parse_model (shared with continue)"
fi
( mkdir -p "$TMP/repo" && cd "$TMP/repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
refused "crew -m fable" bash -c 'cd "$1" && shift && bash "$@"' bash "$TMP/repo" "$SRC" crew -m fable --check true -- "task"
[ -z "$(cd "$TMP/repo" && git worktree list | sed -n 2p)" ] && ok "crew refusal happens before any worktree is created" || bad "crew created a worktree before refusing"
# env-only exclusion is enforced the same way
mv "$OSRC_HOME/exclude" "$TMP/exclude.hold"
: > "$CALLS"; o="$(OSRC_EXCLUDE_MODELS=fable run run -m fable "hi" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$o" | grep -q "you excluded 'fable'" && [ ! -s "$CALLS" ] && ok "OSRC_EXCLUDE_MODELS alone refuses -m too" || bad "env-only refusal: $o"
mv "$TMP/exclude.hold" "$OSRC_HOME/exclude"
# an allowed model still routes (exclusion is not a blanket block)
o="$(run run -m opus "hi" 2>&1)"
printf '%s' "$o" | grep -q "you excluded" && bad "opus was wrongly refused: $o" || ok "an allowed model is not refused"

# ---------------------------------------------------------------- provider defaults (automatic choice)
: > "$CALLS"; o="$(OSRC_EXCLUDE_MODELS=glm run --provider devin run "hi" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$o" | grep -q 'default model for --provider devin' && [ ! -s "$CALLS" ] \
  && ok "a provider's built-in default that is excluded is refused with the fix, never run" || bad "provider default: $o"

# ---------------------------------------------------------------- automatic choices skip excluded
r="$(OR_OFFLOAD_CHAIN='z-ai/glm-5.2,anthropic/claude-5-fable,deepseek/deepseek-v4-pro' lib 'MODEL_EXPLICIT=0; _or_chain auto' 2>/dev/null)"
[ "$r" = "z-ai/glm-5.2 deepseek/deepseek-v4-pro" ] && ok "OpenRouter chain drops excluded rungs" || bad "or chain: '$r'"
o="$(OR_OFFLOAD_CHAIN='anthropic/claude-5-fable' lib 'MODEL_EXPLICIT=0; _or_chain auto; echo survived' 2>&1)"
printf '%s' "$o" | grep -q 'every model in the OpenRouter chain' && ! printf '%s' "$o" | grep -q survived \
  && ok "an all-excluded OpenRouter chain stops with a clear message" || bad "all-excluded chain: $o"
r="$(lib '_fallback_lane_ready() { return 0; }; _fallback_pick "" "fable|fable|cc
opus|opus|cc"' 2>/dev/null)"
[ "$r" = "opus|opus|cc" ] && ok "fallback shortlist pick skips an excluded candidate" || bad "fallback pick: '$r'"
r="$(lib '_model_denied fable && echo denied; _model_denied claude-opus-4-8 && echo bad || echo allowed' 2>/dev/null | tr '\n' ' ')"
[ "$r" = "denied allowed " ] && ok "_model_denied (failover lane check + advise + route choke point) honors the exclude list" || bad "_model_denied: '$r'"
r="$(lib '_lane_down_active() { return 1; }; _fallback_lane_ready() { return 0; }; _lane_ready_probe() { return 0; }; _failover_lane_ok cc run fable && echo ok || echo refused' 2>/dev/null)"
[ "$r" = refused ] && ok "cross-harness failover refuses an excluded model on a ready lane" || bad "failover lane ok: '$r'"
o="$(lib '_escalate_ladder "" ""' 2>&1)"
printf '%s' "$o" | grep -q '^fable$' && bad "escalate ladder kept fable: $o" \
  || { printf '%s' "$o" | grep -q 'dropping ladder rung fable' && ok "escalate default ladder drops the excluded rung, out loud" || bad "ladder notice: $o"; }
: > "$OSRC_HOME/benchmarks.json"
r="$(OSRC_BENCH_JSON="$OSRC_HOME/benchmarks.json" run advise --json --effort max "architect a hard distributed consensus redesign with deep reasoning" 2>/dev/null)"
if printf '%s' "$r" | jq -e '.recommendation.alias' >/dev/null 2>&1; then
  printf '%s' "$r" | jq -r '.recommendation.alias, .recommendation.model, (.shortlist[] | .alias, .model)' | grep -qi fable \
    && bad "advise --json still lists a fable model" || ok "advise --json (recommendation + shortlist) never contains an excluded model"
else bad "advise --json produced no JSON: $(printf '%s' "$r" | head -c 300)"; fi
r="$(OSRC_BENCH_JSON="$OSRC_HOME/benchmarks.json" run advise --effort max "architect a hard distributed consensus redesign" 2>&1)"
printf '%s' "$r" | grep -qi fable && bad "advise text lists fable" || ok "advise text output never names an excluded model"

# second-opinion: default premium judge (fable) swaps to the next allowed premium and says so
SO='_so_run() { echo "$1" >> "$SOLOG"; echo "answer from $1 $RANDOM"; }; _so_agree() { return 1; }; record_ledger() { :; }
_autodetach_should() { return 1; }; _confident_fail() { return 1; }; _so_resolve() { printf "%s|cc|frontier\n" "$1"; }
second_opinion "is the sky blue"'
SOLOG="$TMP/so.log"; export SOLOG; : > "$SOLOG"
o="$(lib "$SO" 2>&1)"
printf '%s' "$o" | grep -q 'premium judge fable is on your exclude list' && grep -qx opus "$SOLOG" && ! grep -q fable "$SOLOG" \
  && ok "second-opinion premium falls back fable -> opus and says so" || bad "so premium: $(cat "$SOLOG" | tr '\n' ' ') $o"
: > "$SOLOG"
o="$(OSRC_EXCLUDE_MODELS=sol lib "$SO" 2>&1)"
printf '%s' "$o" | grep -q 'sol is on your exclude list' && ! grep -qx sol "$SOLOG" \
  && ok "second-opinion default pair swaps an excluded comparison model" || bad "so pair: $(cat "$SOLOG" | tr '\n' ' ') $o"
: > "$SOLOG"
o="$(OSRC_EXCLUDE_MODELS='opus terra gemini-pro sol' lib "$SO" 2>&1)"; rc=$?
printf '%s' "$o" | grep -q 'every fallback judge are on your exclude list' && ! grep -qE '^(fable|opus)$' "$SOLOG" \
  && ok "second-opinion stops clearly when every premium judge is excluded" || bad "so all excluded: $o"

# ---------------------------------------------------------------- suggest hides excluded models
printf '%s' '{"data":[{"id":"anthropic/claude-5-fable","created":9,"context_length":200000,"pricing":{"prompt":"0","completion":"0"}},{"id":"z-ai/glm-5.2","created":8,"context_length":200000,"pricing":{"prompt":"0","completion":"0"}},{"id":"anthropic/claude-fable-5-1","created":7,"context_length":1000,"pricing":{"prompt":"0.00001","completion":"0.00002"}}]}' > "$OSRC_HOME/models.json"
o="$(PATH="$FB:/usr/bin:/bin:$(dirname "$(command -v jq)")" run suggest 2>&1)"
printf '%s' "$o" | grep -q 'z-ai/glm-5.2' && ! printf '%s' "$o" | grep -qi 'fable' \
  && ok "suggest/deals hides excluded models (OpenRouter rows + subscription line)" || bad "suggest: $o"

# ---------------------------------------------------------------- brief + doctor show the list
o="$(run brief 2>&1)"
printf '%s' "$o" | grep -q '^excluded    : fable' && ok "brief prints the active exclusions (sticks across sessions)" || bad "brief: $(printf '%s' "$o" | head -20)"
o="$(run doctor 2>&1)"
printf '%s' "$o" | grep -q 'excluded    : fable' && ok "doctor prints the active exclusions" || bad "doctor: $(printf '%s' "$o" | grep -i exclu)"
o="$(OSRC_HOME="$TMP/empty-state" run doctor 2>&1)"
printf '%s' "$o" | grep -q 'excluded models: none' && ok "doctor says none when nothing is excluded" || bad "doctor none"

echo "---"
echo "test_factory_exclude: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
