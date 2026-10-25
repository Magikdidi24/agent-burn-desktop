# Providers: what is read, and from where

The `agent-burn` CLI does all the reading; `Burn.qml` derives the state of each agent from it
([`providerState()`](../shared/Burn.qml)). The facts about the CLI below come from its
code at the pinned revision (20.0.21, `9ce6d8e`) and from 73 real runs done during the audit.

Two principles:

- **Only the CLI's signals**, never the presence of files: the app does not check whether `~/.claude` or
  `~/.codex` exist. The CLI says neither "not signed in" nor "offline", and writes `0` where it means
  "unknown": the state is derived from what it returns, and what is missing stays shown as missing.
- **Nothing made up**: a missing amount is `null` ("—"), an expired limit is not shown, a stale reading is
  flagged as such.

## Claude Code

**What the CLI reads** (on Windows, everything is under `%USERPROFILE%`, since the app sets `HOME=%USERPROFILE%`):

| What | Where | For |
|---|---|---|
| Session logs | `projects/` in `~/.claude` and in `$XDG_CONFIG_HOME/claude`, or in the directories of `CLAUDE_CONFIG_DIR` (comma-separated list; each one must contain `projects/`, otherwise the whole report fails) | spend, tokens, models, days |
| Plan | `~/.claude.json` (`oauthAccount`), the one in `CLAUDE_CONFIG_DIR` first | plan name and price |
| Sign-in token | `~/.claude/.credentials.json`, always under `HOME`, even with `CLAUDE_CONFIG_DIR` | live limits |
| Limits cached by Claude Code | `~/.claude.json` (`cachedUsageUtilization`) | limits without a network call |

Unreadable lines or files without read permission: ignored without a message (exit code 0).

**Live limits.** The CLI queries `api.anthropic.com/api/oauth/usage` (5 s timeout). It shares its
last reading for 55 s across all its processes (cache `~/.cache/agent-burn/claude-usage.json`), and waits
1 to 15 min after a 429. An expired token is renewed with `platform.claude.com` (15 s), and the new
token rewrites `~/.claude/.credentials.json`.

What `Burn` gets from it:

- **Account**: `claudeAccount` from the summary (with `--value`, online only): 5-hour session, week,
  per-model limits (`scoped`), extra credits, time of the reading (`observedAtMs`). Kept in
  `burn-quota.json` and shown until a newer reading arrives, even if the CLI fails.
- **Light reading**: `AGENT_BURN_QUOTA_ONLY=1 agent-burn harness claude --json --no-color` returns the week and
  the session (`observedAt`, `window`, `sessionWindow`), in 0.3 s, without reading the logs. It is the background
  round when the tightest limit is a Claude window. The per-model limits and the credits keep the
  values from the last summary. A failure (exit code 1 "Live quota unavailable" offline) is silent: it only shows
  in the recent errors.
- **Detail page**: `harness claude` gives the plan economics (`economics`) and the breakdown by token
  type (`spendMix`) for the Claude page of the dashboard.
- **Freshness**: `limitsStale` as soon as the reading is older than `staleAfter` = max(10 min, 2 × `cadence`),
  that is two background rounds (one missed reading): 10 min at the 1 and 5 min intervals, 30 min at 15 min,
  60 min at 30 min; or as soon as the sign-in needs checking.
- **Past reset**: a window whose reset time has passed starts again at 0%, without waiting for a reading.

**Sign-in signal.** The only one is `claudeAccountStatus: "signInExpired"` in the summary. The CLI produces it
when the token renewal is refused… but also when the token has expired and the network is missing (waking
from sleep before the Wi-Fi is back). After a refusal, it blocks attempts for 10 min (`AGENT_BURN_FORCE_REFRESH=1`,
set by "Refresh", overrides this). Hence the label "Check sign-in", which names both causes, and never
"Sign in". The status goes away with the next summary that lacks it, or as soon as a light reading succeeds.
With no token at all, or offline with a valid token, the CLI returns neither account nor status: it is
"Local usage", or "Stale reading" if an account read earlier is still stored.

**Pricing.** Online, prices from LiteLLM (raw.githubusercontent.com), otherwise models.dev, 10 s each. Offline or
unreachable: prices built into the CLI, which do not know the recent Claude models (`claude-*-5-5`,
`opus-5` at the pinned revision) and count them at $0, without saying so, with much more computation (65 s of
CPU instead of 2 on a real history during the audit). On the app side:

- `pricingMissing`: tokens > 0 and total cost 0 → banner "Pricing unavailable: amounts incomplete (network
  down or pricing not downloaded)";
- `priced(cost, tokens)`: tokens with a zero cost are shown as "—", never "$0.00" (totals, days, agents,
  models, charts);
- the archive keeps the already known cost of a day that drops back to $0 with tokens.

## Codex

**What the CLI reads**: `$CODEX_HOME` (comma-separated list) or `~/.codex`: `sessions/` and
`archived_sessions/` for spend and tokens.

**Limits.** Online with `~/.codex/auth.json`, the CLI queries `chatgpt.com/backend-api/wham/usage`. Otherwise it
takes the most recent `rate_limits` from its logs (last 24 files), without looking at their age, and
still reports `liveLimits: true`. The summary gives them in `subscription.agents[]`: plan, price,
`window` (week: `usedPercent`, `elapsedMinutes`) and `shortWindow` (session: `usedPercent` only).

What `Burn` gets from it:

- **Week**: computed reset = report time + (7 days − `elapsedMinutes`).
- **Session**: assumed to last 5 h, with no reset time (the CLI does not give one): no forecast,
  "Unknown pace" as soon as it has some usage.
- **Expiry**: if `window.elapsedMinutes` ≥ 7 days (logs older than a week), no window is
  shown, session included: neither the old %, nor a false 0%. The agent switches to "Local usage" and no longer
  counts for the icon.
- **Detail page**: `harness codex` (plan economics, breakdown) for the Codex page of the dashboard.
- **Sign-in**: no signal. The CLI treats any refusal from the API as a missing response: Codex is
  never "Check sign-in".

Codex has only been seen through fixtures (synthetic session: Plus plan, week 34%, session 12%;
9-day-old logs for the expiry), never with a real account.

## Other agents

`Burn.qml` registry: Cursor, OpenCode, Gemini, Pi, Droid, OpenClaw, Kimi, Amp, Qwen (name, color, icon).
An agent that the CLI returns without being in the registry is shown with its id and a gray tint.

- **Usage only**: spend, tokens, models and days, as `agents[]` gives them.
- **No detail page**: the CLI has a `harness` only for `claude` and `codex`.
- **Limits**: only if the CLI puts them in `subscription.agents[]`, read the same way as Codex
  (windows assumed to last 5 h and 7 days, expiry at 7 days). Cursor credits (`cursorAccount`) are
  not read.

## Provider states

`Burn.providerState(agent)` returns `{ state, label, detail, error, at }`. Rules in this order, the first one
that applies wins:

| # | `state` | CLI signal | Label | Detail shown |
|---|---|---|---|---|
| 1 | `unavailable` | the binary does not start (summary, period or harness) | CLI not found | `Burn.cliHint` (bar: "agent-burn CLI not found (~/.local/bin/agent-burn): rerun install.sh"; app: "Agent Burn can't find its CLI (<path>): reinstall the app.") |
| 2 | `unavailable` | no summary, neither successful nor cached, and `Burn.error` set (summary or period failed) | Report failed | `Burn.error`, the message from the CLI (see [ARCHITECTURE.md](ARCHITECTURE.md#errors)) |
| 3 | `unknown` | no summary, neither successful nor cached, and no error | Unknown | No report from the agent-burn CLI yet. |
| 4 | `expired` | Claude: `claudeAccountStatus: "signInExpired"` | Check sign-in | Limits refused: network unavailable, or sign-in expired (run claude, then /login). |
| 5 | `none` | no `claudeAccount` (Claude), no row in `agents[]`, nor in `subscription.agents[]` | Not detected | agent-burn finds neither usage nor a subscription for this agent. |
| 6 | `live` | limits present and fresh: Claude, reading newer than `staleAfter`; others, window not expired and report "Live" | Live | Claude: Limits read from the Claude account, recent reading. Others: Limits from the latest agent-burn report (API or session logs). |
| 6 | `stale` | limits present but stale: Claude, reading older than `staleAfter`; others, report "Cached" | Stale reading | Claude: Last known limits: no reading for more than N min (N = `staleAfter`, 10 at least). Others: Last known limits, cached agent-burn report. |
| 7 | `local` | usage without a limit: Claude without an account; others without a window, or with an expired window | Local usage | Claude: Spend read from the logs; limits unavailable (not signed in or offline). Others: Spend read from the logs; limits missing or expired. |

- `error`: last error from the harness of this agent (`harnessErrors[agent]`), shown on its page only.
- `at`: time of the reading used (`observedAtMs` for Claude, otherwise the time of the report); 0 for `unavailable`
  and `unknown`.
- A failed report reuses the `state: "unavailable"` of the CLI not found case: popover, dashboard and Settings
  give it the same alert tint.
- An agent known only from the local archive (logs purged) is `none`, but keeps its days in the
  history.
- The function only reads: it is evaluated in the QML bindings on every clock tick.

The same labels show up everywhere: tab and page badge, Providers card, Settings →
Providers, tray icon menu (without a limit), diagnostics text.

## What is not available, and is never made up

| Information | Why | Shown instead |
|---|---|---|
| Why the Claude limits are missing (not signed in, offline, 429) | no status from the CLI | "Local usage" with both possible causes |
| Expired Codex sign-in | no signal from the CLI | nothing: Codex stays "Local usage" or "Live" depending on its windows |
| Reset time of the Codex session | missing from the report | window without a time, "Unknown pace" |
| Codex limits older than 7 days | the CLI gives them as current | no window |
| Price of a model the CLI does not know | counted as $0 by the CLI | "—" and the pricing banner |
| Actual duration of non-Claude windows | CLI labels not read | 5 h / 7 days assumption (shortcut documented in `windows()`) |
| Cursor credits, Cursor pages of the Mac app | not ported | nothing |
| Presence of an agent on the machine | never inferred from files | "Not detected" as long as the CLI does not see it |
| Unreadable log files | silently ignored by the CLI | nothing: the spend may be partial |
