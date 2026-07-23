import { UsageEvent } from "./logReader";

export interface Report {
  windowLabel: string;
  since: Date;
  totalCostUSD: number;
  totalMessages: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalCacheReadTokens: number;
  totalCacheWriteTokens: number;
  byProject: { project: string; costUSD: number; messages: number }[];
  byModel: { model: string; costUSD: number; messages: number; matched: boolean }[];
  unmatchedModels: string[];
}

export function buildReport(events: UsageEvent[], windowLabel: string, since: Date): Report {
  const byProjectMap = new Map<string, { costUSD: number; messages: number }>();
  const byModelMap = new Map<string, { costUSD: number; messages: number; matched: boolean }>();

  let totalCostUSD = 0;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalCacheReadTokens = 0;
  let totalCacheWriteTokens = 0;

  for (const ev of events) {
    totalCostUSD += ev.costUSD;
    totalInputTokens += ev.tokens.inputTokens;
    totalOutputTokens += ev.tokens.outputTokens;
    totalCacheReadTokens += ev.tokens.cacheReadInputTokens;
    totalCacheWriteTokens += ev.tokens.cacheCreationInputTokens;

    const p = byProjectMap.get(ev.project) ?? { costUSD: 0, messages: 0 };
    p.costUSD += ev.costUSD;
    p.messages += 1;
    byProjectMap.set(ev.project, p);

    const m = byModelMap.get(ev.model) ?? { costUSD: 0, messages: 0, matched: ev.modelMatched };
    m.costUSD += ev.costUSD;
    m.messages += 1;
    byModelMap.set(ev.model, m);
  }

  const byProject = [...byProjectMap.entries()]
    .map(([project, v]) => ({ project, ...v }))
    .sort((a, b) => b.costUSD - a.costUSD);

  const byModel = [...byModelMap.entries()]
    .map(([model, v]) => ({ model, ...v }))
    .sort((a, b) => b.costUSD - a.costUSD);

  const unmatchedModels = byModel.filter((m) => !m.matched).map((m) => m.model);

  return {
    windowLabel,
    since,
    totalCostUSD,
    totalMessages: events.length,
    totalInputTokens,
    totalOutputTokens,
    totalCacheReadTokens,
    totalCacheWriteTokens,
    byProject,
    byModel,
    unmatchedModels,
  };
}

function money(n: number): string {
  return `$${n.toFixed(2)}`;
}

function fmtTokens(n: number): string {
  return n.toLocaleString("en-US");
}

export function renderReport(report: Report, threshold: number): string {
  const lines: string[] = [];
  lines.push(`SpendSentry — Claude Code local usage report`);
  lines.push(`Window: last ${report.windowLabel} (since ${report.since.toISOString()})`);
  lines.push("");

  if (report.totalMessages === 0) {
    lines.push("No Claude Code assistant turns found in this window under ~/.claude/projects/.");
    lines.push("(Either you haven't used Claude Code recently, or logs live elsewhere on this machine.)");
    return lines.join("\n");
  }

  lines.push(`Estimated spend:   ${money(report.totalCostUSD)}  (threshold: ${money(threshold)})`);
  lines.push(`Assistant turns:   ${report.totalMessages}`);
  lines.push(
    `Tokens:            input ${fmtTokens(report.totalInputTokens)} / output ${fmtTokens(
      report.totalOutputTokens
    )} / cache-write ${fmtTokens(report.totalCacheWriteTokens)} / cache-read ${fmtTokens(
      report.totalCacheReadTokens
    )}`
  );
  lines.push("");

  lines.push("By project:");
  for (const p of report.byProject.slice(0, 10)) {
    lines.push(`  ${money(p.costUSD).padEnd(9)} ${p.messages.toString().padStart(5)} turns  ${p.project}`);
  }
  if (report.byProject.length > 10) lines.push(`  ... and ${report.byProject.length - 10} more`);
  lines.push("");

  lines.push("By model:");
  for (const m of report.byModel) {
    const flag = m.matched ? "" : "  [unrecognized model, sonnet-rate estimate used]";
    lines.push(`  ${money(m.costUSD).padEnd(9)} ${m.messages.toString().padStart(5)} turns  ${m.model}${flag}`);
  }
  lines.push("");

  lines.push(
    "Note: figures are ESTIMATES from local token counts x a hardcoded public pricing table."
  );
  lines.push(
    "Claude Code's local logs do not record a dollar cost, and subscription plans don't always"
  );
  lines.push("map 1:1 to metered API pricing. Treat this as directional, not your invoice.");

  if (report.totalCostUSD > threshold) {
    lines.push("");
    lines.push(`OVER THRESHOLD: ${money(report.totalCostUSD)} > ${money(threshold)}`);
  }

  return lines.join("\n");
}
