# SpendSentry

A local-first CLI that watches your own Claude Code usage logs and warns you
before you blow your budget. No backend, no network calls, no other vendors'
tokens.

## Why

Agentic coding tools can burn through a lot of tokens fast — a long debugging
session or a big refactor can add up to real money before you notice. Every
existing usage tool is either passive (a dashboard you have to remember to
check) or requires an Enterprise plan. SpendSentry is a personal circuit
breaker: it reads the session logs Claude Code already writes to your own
disk (`~/.claude/projects/**/*.jsonl`) and tells you, locally, when you've
crossed a threshold.

**Scope (v0):** single-user, local-only. Reads only your own Claude Code
session logs. No Cursor support, no CI/team enforcement, no data leaves your
machine. Cost figures are *estimates* from token counts x a hardcoded public
pricing table — not a substitute for your actual Anthropic invoice.

## Install

Run it directly, no install step:

```bash
npx github:manhphanxiii/spendsentry check --threshold 5 --window 24h
```

Want a bare `spendsentry` command instead of typing `npx` every time? Clone and link it:

```bash
git clone https://github.com/manhphanxiii/spendsentry.git
cd spendsentry
npm install
npm run build
npm link
```

## Usage

```bash
spendsentry check --threshold 5 --window 24h
spendsentry check --threshold 20 --window 7d --json
spendsentry watch --threshold 5 --window 24h --interval 15
```

- `check` prints a report of estimated spend in the given window and exits
  non-zero if it's over `--threshold`. Safe to wire into a personal
  pre-commit hook, shell prompt, or cron job.
- `watch` re-runs `check` on a timer and fires a desktop notification
  (macOS only in v0, via `osascript`) when you cross the threshold.

Run `spendsentry --help` for the full flag reference.

## How it works

Claude Code writes one JSONL file per session under `~/.claude/projects/`,
with a `usage` block (input/output/cache tokens) on each assistant turn.
SpendSentry walks those files, dedupes by message id (a single turn can span
several JSONL lines), and multiplies token counts by a per-model-tier public
pricing table to estimate cost. Nothing is sent anywhere — it's just reading
files already on your own disk.

## Limitations

- Estimates only. Local logs don't carry an actual dollar cost, and
  subscription plans don't always map 1:1 to metered API pricing.
- macOS-only desktop notifications in v0.
- No Cursor or Codex support yet, and no team/CI-level aggregation — this is
  a personal tool, not a team enforcement gate.
