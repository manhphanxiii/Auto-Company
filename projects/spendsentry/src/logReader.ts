import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { UsageTokens, estimateCostUSD, rateForModel } from "./pricing";

export interface UsageEvent {
  timestamp: Date;
  model: string;
  sessionId: string;
  project: string; // the ~/.claude/projects/<encoded-cwd> directory name
  cwd: string;
  tokens: UsageTokens;
  costUSD: number;
  modelMatched: boolean;
}

export interface ReadOptions {
  claudeDir?: string; // override for tests, defaults to ~/.claude
  since?: Date;
}

/** Default location Claude Code persists session transcripts on disk. */
export function defaultClaudeProjectsDir(): string {
  return path.join(os.homedir(), ".claude", "projects");
}

function walkJsonlFiles(dir: string): string[] {
  const out: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkJsonlFiles(full));
    } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      out.push(full);
    }
  }
  return out;
}

/**
 * Reads every local Claude Code session transcript (JSONL) under
 * ~/.claude/projects/** and returns one UsageEvent per assistant turn that
 * carries a token usage block.
 *
 * Important dedupe note: a single assistant turn can be split across several
 * JSONL lines (thinking block, text block, tool_use block, ...) that all
 * share the same message.id and repeat the *same* cumulative usage numbers.
 * Counting every line would triple- or quadruple-count tokens. We dedupe by
 * message.id and only count the first line we see for a given id.
 */
export function readUsageEvents(opts: ReadOptions = {}): UsageEvent[] {
  const claudeDir = opts.claudeDir ?? path.join(os.homedir(), ".claude");
  const projectsDir = path.join(claudeDir, "projects");
  const files = walkJsonlFiles(projectsDir);

  const events: UsageEvent[] = [];
  const seenMessageIds = new Set<string>();

  for (const file of files) {
    const project = path.relative(projectsDir, file).split(path.sep)[0] ?? "unknown";
    let raw: string;
    try {
      raw = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }

    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      let entry: any;
      try {
        entry = JSON.parse(line);
      } catch {
        continue; // tolerate partial/corrupt lines (e.g. a crash mid-write)
      }

      if (entry?.type !== "assistant") continue;
      const message = entry.message;
      const usage = message?.usage;
      if (!usage) continue;

      const model: string | undefined = message.model;
      if (!model || model === "<synthetic>") continue; // synthetic turns carry no real cost

      const msgId: string | undefined = message.id;
      const dedupeKey = msgId ?? entry.uuid;
      if (dedupeKey) {
        if (seenMessageIds.has(dedupeKey)) continue;
        seenMessageIds.add(dedupeKey);
      }

      const timestamp = entry.timestamp ? new Date(entry.timestamp) : null;
      if (!timestamp || Number.isNaN(timestamp.getTime())) continue;
      if (opts.since && timestamp < opts.since) continue;

      const tokens: UsageTokens = {
        inputTokens: usage.input_tokens ?? 0,
        outputTokens: usage.output_tokens ?? 0,
        cacheCreationInputTokens: usage.cache_creation_input_tokens ?? 0,
        cacheReadInputTokens: usage.cache_read_input_tokens ?? 0,
      };

      const { matched } = rateForModel(model);

      events.push({
        timestamp,
        model,
        sessionId: entry.sessionId ?? "unknown",
        project,
        cwd: entry.cwd ?? "unknown",
        tokens,
        costUSD: estimateCostUSD(model, tokens),
        modelMatched: matched,
      });
    }
  }

  return events;
}

export function parseWindow(window: string): number {
  const m = /^(\d+)\s*(h|d)$/i.exec(window.trim());
  if (!m) {
    throw new Error(`Invalid --window "${window}". Use e.g. 24h, 7d, 30d.`);
  }
  const n = Number(m[1]);
  const unit = m[2].toLowerCase();
  const hourMs = 60 * 60 * 1000;
  return unit === "h" ? n * hourMs : n * 24 * hourMs;
}
