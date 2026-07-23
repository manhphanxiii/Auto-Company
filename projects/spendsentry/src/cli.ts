#!/usr/bin/env node
import { readUsageEvents, parseWindow } from "./logReader";
import { buildReport, renderReport } from "./report";
import { notify } from "./notify";

interface Flags {
  threshold: number;
  window: string;
  notify: boolean;
  json: boolean;
  interval: number; // minutes, for watch
}

function parseArgs(argv: string[]): { command: string; flags: Flags } {
  const command = argv[0] ?? "help";
  const flags: Flags = { threshold: 5, window: "24h", notify: false, json: false, interval: 15 };

  let i = 1;
  const takeValue = (name: string): string => {
    const value = argv[++i];
    if (value === undefined || value.startsWith("--")) {
      console.error(`Error: ${name} requires a value.`);
      process.exit(2);
    }
    return value;
  };

  for (; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "--threshold":
        flags.threshold = Number(takeValue("--threshold"));
        break;
      case "--window":
        flags.window = takeValue("--window");
        break;
      case "--notify":
        flags.notify = true;
        break;
      case "--json":
        flags.json = true;
        break;
      case "--interval":
        flags.interval = Number(takeValue("--interval"));
        break;
      default:
        console.error(`Unknown flag: ${arg}`);
        process.exit(2);
    }
  }
  return { command, flags };
}

/** Validates flags shared by `check` and `watch`. Returns an error message, or null if valid. */
function validateFlags(flags: Flags, opts: { requireInterval: boolean }): string | null {
  if (!Number.isFinite(flags.threshold) || flags.threshold <= 0) {
    return "--threshold must be a positive number (USD).";
  }
  try {
    parseWindow(flags.window);
  } catch (e: any) {
    return e.message;
  }
  if (opts.requireInterval && (!Number.isFinite(flags.interval) || flags.interval <= 0)) {
    return "--interval must be a positive number (minutes).";
  }
  return null;
}

function runCheck(flags: Flags): number {
  const error = validateFlags(flags, { requireInterval: false });
  if (error) {
    console.error(`Error: ${error}`);
    return 2;
  }

  const windowMs = parseWindow(flags.window);
  const since = new Date(Date.now() - windowMs);
  const events = readUsageEvents({ since });
  const report = buildReport(events, flags.window, since);

  if (flags.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(renderReport(report, flags.threshold));
  }

  const over = report.totalCostUSD > flags.threshold;

  if (over && flags.notify) {
    notify(
      "SpendSentry: over budget",
      `Estimated Claude Code spend in last ${flags.window} is $${report.totalCostUSD.toFixed(2)} (threshold $${flags.threshold.toFixed(2)})`
    );
  }

  return over ? 1 : 0;
}

async function runWatch(flags: Flags): Promise<number> {
  const error = validateFlags(flags, { requireInterval: true });
  if (error) {
    console.error(`Error: ${error}`);
    return 2;
  }

  const intervalMs = flags.interval * 60 * 1000;
  console.log(
    `SpendSentry watch: checking every ${flags.interval}m, threshold $${flags.threshold}, window ${flags.window}. Ctrl+C to stop.`
  );

  const tick = () => {
    const windowMs = parseWindow(flags.window);
    const since = new Date(Date.now() - windowMs);
    const events = readUsageEvents({ since });
    const report = buildReport(events, flags.window, since);
    const stamp = new Date().toLocaleTimeString();
    const status = report.totalCostUSD > flags.threshold ? "OVER" : "ok";
    console.log(
      `[${stamp}] estimated spend $${report.totalCostUSD.toFixed(2)} / threshold $${flags.threshold.toFixed(2)} — ${status}`
    );
    if (report.totalCostUSD > flags.threshold) {
      notify(
        "SpendSentry: over budget",
        `Estimated Claude Code spend in last ${flags.window} is $${report.totalCostUSD.toFixed(2)} (threshold $${flags.threshold.toFixed(2)})`
      );
    }
  };

  tick();
  setInterval(tick, intervalMs);
  // keep process alive; user Ctrl+C's out
  return 0;
}

function printHelp(): void {
  console.log(`spendsentry — local-first Claude Code spend watchdog (v0)

Usage:
  spendsentry check --threshold <usd> [--window 24h|7d|30d] [--notify] [--json]
  spendsentry watch --threshold <usd> [--window 24h] [--interval <minutes>]

check   Summarize estimated Claude Code spend from local session logs in the
        given window and exit non-zero if it exceeds --threshold. Safe to
        wire into a personal pre-commit hook or shell prompt if you want.

watch   Re-run the check on a timer and fire a desktop notification
        (macOS only in v0) when you cross the threshold.

Options:
  --threshold <usd>   Dollar budget for the window. Default: 5
  --window <spec>     Lookback window, e.g. 24h, 7d, 30d. Default: 24h
  --notify            (check only) fire one notification if over threshold
  --json              (check only) print machine-readable JSON report
  --interval <min>    (watch only) minutes between checks. Default: 15

Scope (v0): single-user, local-only, reads only your own Claude Code session
logs under ~/.claude/projects/. No network calls, no Cursor support, no CI
enforcement, no team aggregation. Cost figures are ESTIMATES — see README.
`);
}

async function main() {
  const { command, flags } = parseArgs(process.argv.slice(2));

  let exitCode = 0;
  switch (command) {
    case "check":
      exitCode = runCheck(flags);
      break;
    case "watch":
      exitCode = await runWatch(flags);
      break;
    case "help":
    case "--help":
    case "-h":
      printHelp();
      break;
    default:
      console.error(`Unknown command: ${command}\n`);
      printHelp();
      exitCode = 2;
  }
  process.exitCode = exitCode;
}

main();
