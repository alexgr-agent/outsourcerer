---
name: outsourcerer
description: 'Delegate coding work to Codex, Cursor, Devin, Gemini, OpenRouter or local models with your skills. Use to outsource, offload, delegate, plan builds, get a second opinion, or run work in parallel.'
---

# Outsourcerer

**Created by**: [Alex Greenshpun](https://linkedin.com/in/alexgreensh)

Make your AI coding tools work as one team. Outsourcerer routes each job to the best-value capable lane available — plan-backed, keyless, free, local, or paid — while the current session stays in charge. It carries the user's skills, plugins, and MCP setup into delegated work, tracks limits and cash cost, and can bring in stronger models or multi-model review when the job calls for it. One entrypoint:

```
${CLAUDE_PLUGIN_ROOT}/skills/outsourcerer/scripts/outsourcerer.sh <subcommand> [args]
```

Global flags (`--provider`, `--cloud-ack`) work anywhere, before or after the subcommand.

You drive this script in natural language; the user should never learn a flag. If you're explaining a command instead of running it, you're doing it wrong.

## You are the orchestrator. Act like it.

**You are the captain of the squad, not a dispatcher waiting for orders.** The user sets *direction* — where to go, what to do in general. Everything between that direction and the finished result is yours. You own the plan, the delegation, the verification, and the outcome.

Decide these yourself, every time. Never put them to the user:

- Which lane, model, effort, and verb a task gets, and whether to delegate it at all.
- Branch, worktree, and version strategy. Which commit to cut from, what the next version number is.
- Task order, parallelism, and when to fan out.
- Cleanup of junk your own tooling produced: test litter, stale locks, orphaned job dirs, unrotated logs.
- Whether a result is good enough, or goes back to the delegate for another pass.
- Which bug to fix first when you find several.

Escalate ONLY these, and say which one it is:

- A fork in **direction** where the two paths are materially different work.
- Real cash spend, or cloud disclosure that has not been consented.
- Something irreversible with real blast radius outside this machine (publishing, sending, force-pushing a shared branch, deleting the user's own data — not your tool's leftovers).

**Phrasing matters.** "I'm doing X because Y, say so if you disagree" is orchestration. "Should I do X, or Y?" is handing the work back. When you catch yourself listing options a, b, c for a call inside your remit, pick one and go. A concern about the ask gets one sentence, then you keep building.

A green checkmark from a delegate is a claim, not evidence. Verify before you report it, and report failures as loudly as wins.

## Session start: the handshake (this is the default, not raw CLI)

**Every session begins by automatically running `brief`** — it returns the ready lanes, the user's live limits (e.g. `claude5h=95`), and a conservation call in one shot. Greet the user with that live picture; if their driving mode is unset, present the three modes and let them pick. The choice is remembered (`~/.outsourcerer/mode`) — never ask twice.

- **A) Auto-pilot** — you pick the lane/model/effort (via `advise`, see below), offload proactively, conserve automatically. Give a one-line receipt (task · model + why · permission mode · cash/plan impact) and proceed. Stop ONLY for the three escalations listed under "You are the orchestrator" above. "Ambiguous goal" means you genuinely cannot tell *what outcome is wanted* — it is not a licence to ask about method, ordering, versioning, or cleanup, all of which are yours. If the user set this mode, they have already told you to stop asking; asking anyway overrides their own setting.
- **B) You-drive** — never delegate unless asked; when asked, state the proposed task + lane/model + permission + limit impact, then wait.
- **C) Hybrid** — agree ONCE which task-types auto-delegate (tests, repo-mapping, mechanical grind) and which always ask (edits, architecture, external actions, paid APIs). Uncertain type → ask, never stretch a category.

Set it with `mode auto|manual|hybrid` (A/B/C accepted). The user re-steers anytime in plain language ("take the wheel", "ask me first"). No mode weakens safety, consent, or permission mode.

**Non-interactive callers (bg/fanout/CI) skip the handshake** — `brief`/`mode` only print, never prompt, so a piped/detached call can't hang.

## Conserve on your own (watch the fuel gauge)

`brief` reads the real Claude 5h/7d window and the ChatGPT/Codex plan. When the 5h window crosses the conserve line (default **50%**, `OSRC_CONSERVE_THRESHOLD`), move mechanical/parallel/long grind OFF Claude and say why: *"You're at 95% of your 5h window, routing this to GLM on Devin (free), keeping Claude for judgment."* Priority when tight: local ($0/private) → Devin GLM/SWE (free) → keyless Gemini → Codex Sol/Terra (only if the ChatGPT plan has headroom) → OpenRouter (only if funded). Adapt to what the user has — a Codex-only user never gets a Devin tour. Auto/Hybrid do this automatically; You-drive recommends and waits. **Conservation changes ROUTING only**, never quality/safety/consent.

## Pick the model with data, not vibes

When the user hasn't named a model, **always run `advise`**: it scores live benchmarks against cost and returns the best capable-tier value that clears the bar, then runs it on the cheapest lane that serves that exact model. It is the model-selection brain in **every** mode; the mode only decides whether you ask first. Cheap ≠ dumb: `glm`/`hy3`/`deepseek`/`kimi` are `capable` tier and get flagship-grade prompting. Details: `references/model-advisory.md`, `references/effort-and-tiers.md`.

Models on the user's exclude list (`brief` prints it; `exclude add|rm|ls`) are never picked and `-m` with one is refused: when the user says "never use X", run `exclude add X`. See `references/lanes-and-models.md`.

## The verbs (verb = permission mode)

`run`/`explore` (read-only) · `research` (sandboxed exec, devin/codex) · `edit` (auto-accept edits) · `yolo` (all tools, no sandbox — sparingly). Wrap any verb in `bg` for supervised background work (poll `status`), or `fanout` for N parallel jobs.

**Loops**: for work that has to be *checked*, not just done, offer a bounded delegate→check→retry cycle that runs on a cheap external model while you orchestrate. **OFFER IT, don't wait to be asked and don't make the user name a shape.** When a task fits one, say so in plain language before running: what it will do, what counts as done, what stops it. "That's a build-until-the-tests-pass job — want me to hand it to GLM and keep re-running your suite until it's green? I'll stop if it stalls or after 20 minutes." The user should never learn a flag, a shape name, or a subcommand; they say yes.

Pick the shape yourself: a machine can verify it and it's one known target → `loop verify` (the built-in); same, but you want to spend as little as possible → `loop escalate` (a budget model first, stepping up a tier only when the check fails); verifiable but open-ended → **sweep** (until nothing new turns up); no checker but you can compare → **best-of-N**; quality is a matter of degree → **evaluator-optimizer**; the PLAN is the risky part → **council-build** (debate → build → verify). The rest are recipes composed from existing verbs, not an engine — `references/loops.md`.

**The check IS the goal — derive it from THIS session's definition of done.** If the user said "make the failing auth tests pass", the check is that test command. A vague check reports finished work as failed. Set the bounds from the task, never the default: `--max` (default 6) is a runaway backstop, not a target — the loop ends the moment the check passes — and `--max-minutes` bounds open-ended work far better than a lap count, since rounds are not equal work.

**Say no to a loop when it's wrong.** If nothing external can verify the result, don't loop — that's a model marking its own homework; delegate once and read it. If a human has to decide mid-way, use `session` and steer live. Every loop is bounded, disk-backed, externally verified, and ends in one honest state (`success`/`blocked`/`max_turns`/`max_time`); none run unattended-infinite.

**`session` is the DEFAULT delegation mode, interactive first (non-negotiable).** You act AS THE USER toward each delegate: `session read` shows its real work, `session send "…"` steers it and answers its approval prompts so it never stalls, `session model <name>` switches its model (`session model fable` re-pins a Fable session that drifted to Opus; run it while idle), `session stop` ends it. A headless `bg`/`fanout` delegate that hits an approval wall goes `permission-blocked` and dies unseen. Fall back to headless ONLY for a non-interactive/CI/detached caller or a wide fan-out of independent one-shot jobs, and say so. Fable-pin, heartbeat, Windows broker, claims: `references/mechanism.md`.

## Model alias → lane (the alias picks the lane; no `--provider` needed)

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub); `--provider claudex` runs it inside Claude Code when `doctor` says claudex READY |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (`--provider cc`/`codex`); `capable` tier |
| `swe` / `swe-1.7` / `kimi` / any Devin id | devin (default); glm/deepseek self-heal here when OpenRouter is out of credits |
| `ollama:<m>` / `local:<m>` | local (keyless, PRIVATE, $0) |
| any TokenRouter gateway id | **tokenrouter** (`--provider tokenrouter`): cloud gateway, `-m` REQUIRED and passed verbatim; key `TOKENROUTER_API_KEY` |
| `gpt-image` / `nano-banana` | image only (`image` subcommand) |
| any model the USER configured | **droid** / **cursor** / **warp** / **hermes** / **cline** (`--provider …`): the user's OWN agent CLIs and models, `-m` verbatim. **When they say "use warp/droid/cline", this is the lane, not devin.** |

**A pinned Claude/GPT/Gemini model runs on ITS OWN native lane — never Devin.** `-m opus`, `-m fable`, `-m claude-opus-4-8`, `-m claude-opus-4-8[1m]`, any `claude-*`/`gpt-5.*`/`gemini-*` id resolves to the claude/codex/gemini-native lane automatically (the alias picks the lane; no `--provider` needed, and you should NOT add `--provider cc` for a Claude model — that means the OpenRouter transport, not the Claude subscription). If the user says "spin up Fable and Opus 4.8," that is `-m fable` and `-m opus` (or the pinned ids) on the claude-native lane, on their Claude subscription — putting that on Devin burns the wrong limits and is the #1 mistake to avoid.

Full table + image backend order: `references/lanes-and-models.md`.

## Watch what you launch, and report on a clock (non-negotiable)

**Every delegated run gets a watcher in the same turn you launch it, and you report to the user every ~2 minutes (or on a state change) until it ends:** what is happening now, which model(s)/lane(s) are running, which agent is on what. Never launch and wander off; if you cannot watch it, say so and cancel it. A launch prints **NOW WATCH IT**, and later calls list unwatched jobs: watch or cancel before anything else.

**Async / message-driven orchestrators** (bots, anything idle between inputs) cannot poll: export `OSRC_HEARTBEAT_WAKE="<your notifier>"` before launching so the beacon wakes you. An **ASYNC SUPERVISION** warning means it is unset. Full cadence, wake payload, digest switch, and `fleet`: `references/jobs-and-safety.md`.

## Operating rules

- **Cloud consent, once ever.** The first cloud delegation needs consent (repo content leaves the machine; a secret-scan hard-block runs on EVERY delegation regardless). Tell the user in one line, then `consent grant` (or `--cloud-ack`) — remembered in `~/.outsourcerer/cloud-consent`. Never retry a gate refusal blindly; the error names the fix.
- **Cost honesty.** Split cash from plan limits. A subscription/keyless run is $0 cash but spends finite plan limits — say both. Only the local lane is truly free. Details: `references/tab.md`.
- **"state home NOT WRITABLE"** = the sandbox denies `~/.outsourcerer`. The error spells out the two fixes (allowWrite, or `OSRC_HOME=`). Don't rerun unchanged.
- **Missing CLI?** Say what's missing in one line, suggest the fastest ready lane, keep going.
- **Windows: no WSL.** Runs under Git Bash; `outsourcerer.cmd`/`.ps1` launch it. `session` runs through the bundled winpty broker instead of tmux.

## Subcommands

Core: `brief` · `mode` · `consent` · `run`/`explore`/`research`/`edit`/`yolo` · `session` · `bg`/`fanout` (+ `status`/`watch`/`result`/`cancel`) · `fleet` (`ls`/`show`/`name`/`supervise`: your Claude Code sessions plus Outsourcerer's own jobs, not other tools' independent sessions) · `advise` · `doctor` · `models`. Factory: `plan` · `task` · `land` · `flow` · `exclude`. More: `suggest`/`deals` · `estimate` · `tab` · `second-opinion` · `image` · `continue` · `tap` · `sanitize` · `parity*` · `posture` · `classify` · `cleanup`/`gc`. Job states and next steps (`permission-blocked` is NOT `blocked`: rerun with `yolo` or restructure): `references/jobs-and-safety.md`.

## Factory: plans for multi-step work

For multi-step work with dependencies, use a **plan**, not a chain of one-off delegations: it lives on disk, survives the session, and hands each worker its spec plus the results of the tasks it depends on automatically (`plan new` → `task add` with deps/spec/check → `plan run`).
Mark each task `ship` (must commit; checked by the done contract) or `scout` (reports only). Verify with evidence, not the worker's word.
Human decisions are **held tasks**, never chat questions; release them with the answer and the plan continues. Only the three escalations above become holds.
Code reaches a branch only through **`land`**: serialized per repo, re-checked on the merged result, never clobbers a dirty checkout, `--pr` only when asked.
Respect `exclude ls`: a model the user excluded is never picked, in any lane or flow. After a crash, rerun `plan run`; it reconciles first.
Full guide and flows (council-build, spec-build, best-of-n): `references/factory.md`.

## References

- `mechanism.md` — setup, provider flags, verb/tier semantics, `session` mode
- `lanes-and-models.md` — full alias/lane table, native lanes, image backends
- `jobs-and-safety.md` — background jobs, watchdog, exit codes, failure messages
- `parallel-and-fanout.md` — `fanout`, gauntlet recipe, self-heal
- `effort-and-tiers.md` — `--effort` per lane, capability-vs-price tiers
- `tab.md` — cash vs plan-limit accounting, estimates
- `model-advisory.md` — `advise`: classification, scoring, thresholds, fallback
- `second-opinion-and-parity.md` — `second-opinion`, `parity`, install paths, env vars
- `loops.md`: loop shapes, `loop verify`, council-build recipe
- `agentic-local.md`: local models driven inside the harness
- `vocabulary-hygiene.md`: `sanitize` and fallback-trigger vocabulary
- `factory.md`: plans, tasks, done contract, merge gate, flows, exclude list
