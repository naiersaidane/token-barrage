<h1><img src="assets/icon.svg" width="28" alt="" /> Token Barrage</h1>

*[Version française](README.md)*

> *Barrage*, in French, means dam.

**Most of what a coding agent does isn't thinking. It's I/O.** It opens five files to answer a question about one. It writes the twenty-first test that looks like the twenty before it. Enormous volume, almost no judgment — all of it billed at frontier rates.

token-barrage is a Claude Code plugin that hands that work to a cheap worker model. The expensive model never sees it.

No SaaS. No API key. It runs on the Claude Code subscription you already have.

![Licence: Apache-2.0](https://img.shields.io/badge/licence-Apache--2.0-0061FF) ![Installation: claude plugin](https://img.shields.io/badge/install-claude%20plugin-0061FF) ![Par L'Accélérateur IA](https://img.shields.io/badge/par-L'Acc%C3%A9l%C3%A9rateur%20IA-0F172A)

---

## Install

```bash
claude plugin marketplace add naiersaidane/token-barrage
claude plugin install token-barrage@token-barrage
```

Requires [`jq`](https://jqlang.org) (`brew install jq`) and the `claude` CLI. That's it.

---

## How it works

Three layers, from hard gate to soft suggestion.

**1. Hooks — the part that actually works.**
A `PreToolUse` hook blocks `Read` on any file over 350 lines, and blocks `cat`/`head`/`tail`/`less`/`more` on the same. Targeted reads (`offset`/`limit`), pipes and redirections pass through untouched.

**2. Scripts — the delegation itself.**
`bulk-read` wraps the files in XML tags and sends them to the worker with your question. `code-write` sends a spec plus a reference file and writes the result straight to disk. Neither corpus ever enters the main model's context.

**3. Skills — when to reach for them.**
Two `SKILL.md` files tell the agent when delegation is the right move.

The order matters. Written rules get ignored — that's the whole reason layer 1 exists. **A rule is a suggestion. A block is architecture.**

---

## Measured results

Not estimated. Measured, with real billed tokens.

| Scenario | Lines | Context saved | Range | **Net gain per call** |
|---|---|---|---|---|
| Single large file | 602 | **98.2%** | 97.9 – 98.4 | **+$0.0652** |
| Multi-file cross-read | 692 | **97.3%** | 96.9 – 97.7 | **+$0.0683** |
| Source + test | 90 | 68.2% | 56.4 – 75.6 | **−$0.0024** |
| **Mean** | | **87.9%** | 83.9 – 90.4 | |

Run it yourself:

```bash
bash bench/run.sh
```

### Three things the numbers say

**The savings are real, and above the threshold they're better than advertised.** Spotify reports 82–94% for the equivalent plugin. On the same fixtures, above the line threshold, this measures 97–98% with under a point of spread.

**The 350-line threshold is the line between making money and losing it.** The 90-line scenario is *net negative*: −$0.0024 per call. Worker overhead eats the saving. It's also the least stable — ±10 points, against under one point above the threshold. Below the threshold you don't just lose, you can't predict by how much.

**Cache state drives cost more than corpus size does.** The same scenario costs **$0.0415 cold and $0.0071 warm — 5.9×** — at near-identical payload. The first call pays the cache write for every call after it. The table above reports steady state.

### Method

Token counts come from a **differential measurement**: the same call is made empty and then carrying the text, with identical flags, and the difference isolates the payload. Context total is `input + cache_write + cache_read`, which is independent of cache state. This measures billed tokens rather than approximating them with a `chars / 4` heuristic.

Worker cost is read from `bench/ledger.jsonl`, which records real tokens and real dollars for every delegation — so the table reports **net** gain, not just gross saving.

**Limits, stated plainly:** 3 passes over 3 scenarios, on TypeScript fixtures rather than a large monorepo. Worker is Claude Haiku 4.5. Main-model savings are valued at Claude Opus 5 list input pricing ($5/MTok). Summaries are generative, so they vary between runs — hence the ranges.

---

## What does not get delegated

The plugin is built to know when to stay out of the way.

- **Debugging** — a cheap model finds surface patterns and misses the subtle bug. This needs the expensive model's reasoning, not a summary.
- **Editing** — edits need exact content and exact line numbers. Use a targeted read (`offset`/`limit`) instead.
- **Architecture and safety-critical code** — judgment stays with the expensive model.
- **Small files** — below the threshold, delegation costs more than it saves. The number above is the proof.

---

## Configuration

Set these in the `env` block of `.claude/settings.json`.

| Variable | Default | Purpose |
|---|---|---|
| `BARRAGE_MIN_LINES` | `350` | Line count above which reads are blocked and redirected |
| `BARRAGE_WORKER_MODEL` | `claude-haiku-4-5-20251001` | The worker model |
| `BARRAGE_LEDGER` | `.barrage/ledger.jsonl` | Where per-delegation cost is recorded |

The worker runs with its tool definitions stripped and the Claude Code system prompt replaced — it needs no tools, since the whole corpus is in the message. That cuts fixed overhead from 24,706 tokens to **11,406**, a 54% reduction. In steady state those tokens are served from cache, at roughly **$0.001 per delegation**.

The plugin's own footprint is **~199 tokens added to every session** (two skill descriptions; hooks run in the harness and cost no model context). Verify with `claude plugin details token-barrage@token-barrage`.

---

## Differences from Spotify's shunt

This is a port of [`shunt`](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt), the plugin Spotify published under Apache-2.0. The architecture is theirs. The fixes below came out of porting and measuring it.

| | shunt | token-barrage |
|---|---|---|
| Backend | Portal instance + AiKA (commercial SaaS, trial by application) | Your existing Claude Code subscription |
| Pass-through payload | `{"decision": "allow"}` — invalid in both the legacy (`approve\|block`) and current schemas; Claude Code rejects it on every pass | Exit 0, no output — defers to the normal permission flow |
| Block payload | Deprecated top-level `decision` field | `hookSpecificOutput.permissionDecision` |
| `offset:0` / `limit:0` | Documented bypass | Blocked |
| `head -n 5 big.txt` | Parser reads `5` as the path; passes through | Blocked |
| Request ceiling | `ARG_MAX` — 400 KB macOS, 120 KB Linux | None; the payload goes over stdin |
| Worker cost | Not observable (AiKA is a black box) | Recorded per call in a ledger |

On the pass-through payload: forcing `"allow"` — had it been valid — would have **bypassed the user's own permission prompts** on every `Read` and every Bash command under the threshold. Emitting nothing and exiting 0 is the documented behaviour, and the safe one.

Their own eval suite reads the hook's output with `jq -r '.decision'` and compares it to the string it just produced, so all 51 tests pass while the plugin errors on every pass-through in real use.

---

## Credits

The architecture, the three-layer design, the 350-line threshold and the benchmark scenarios all come from Spotify's [portal-ai-plugins](https://github.com/spotify/portal-ai-plugins). The fixtures in `bench/fixtures/` are theirs, reproduced under Apache-2.0 so the benchmark runs without cloning their repo — and so the comparison is against the exact same corpus.

Apache-2.0.

---

## Going further

If you want to learn Claude Code and turn it into recurring revenue, take a look at **L'Accélérateur IA**.

👉 **[Discover L'Accélérateur IA](https://laccelerateuria.com)**
