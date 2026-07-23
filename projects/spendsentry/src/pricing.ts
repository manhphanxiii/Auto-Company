/**
 * Token pricing table.
 *
 * IMPORTANT — this is an ESTIMATE, not an authoritative bill.
 * Claude Code local session logs (~/.claude/projects/**\/*.jsonl) do NOT contain
 * a dollar cost field. They only contain token counts. Actual spend depends on
 * your plan (subscription vs. metered API key), regional pricing, promos, and
 * whether Anthropic changes prices after this file was written. Treat every
 * number this tool prints as "roughly this much, directionally useful for
 * catching a runaway session" — not as a substitute for your Anthropic invoice.
 *
 * Prices are USD per million tokens, matched by substring against the model
 * name recorded in the session log (e.g. "claude-opus-4-8", "claude-sonnet-5",
 * "claude-haiku-4-5-20251001"). Internal/codename models that don't match a
 * known tier fall back to the Sonnet-tier default and are flagged in the report.
 */

export interface ModelRate {
  /** matched tier label for display */
  tier: string;
  inputPerM: number;
  outputPerM: number;
  /** 5-minute ephemeral cache write premium, per million tokens */
  cacheWritePerM: number;
  /** cache read (hit), per million tokens — much cheaper than a fresh input token */
  cacheReadPerM: number;
}

const RATES: { match: RegExp; rate: ModelRate }[] = [
  {
    match: /opus/i,
    rate: { tier: "opus", inputPerM: 15, outputPerM: 75, cacheWritePerM: 18.75, cacheReadPerM: 1.5 },
  },
  {
    match: /sonnet/i,
    rate: { tier: "sonnet", inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.3 },
  },
  {
    match: /haiku/i,
    rate: { tier: "haiku", inputPerM: 1, outputPerM: 5, cacheWritePerM: 1.25, cacheReadPerM: 0.1 },
  },
  {
    // codenamed / preview models seen in some local builds (e.g. "claude-fable-5")
    // — no public pricing tier is known, so treat as sonnet-equivalent and flag it.
    match: /fable/i,
    rate: { tier: "sonnet (assumed, codename model)", inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.3 },
  },
];

const DEFAULT_RATE: ModelRate = {
  tier: "sonnet (default fallback, unrecognized model)",
  inputPerM: 3,
  outputPerM: 15,
  cacheWritePerM: 3.75,
  cacheReadPerM: 0.3,
};

export function rateForModel(model: string): { rate: ModelRate; matched: boolean } {
  for (const { match, rate } of RATES) {
    if (match.test(model)) return { rate, matched: true };
  }
  return { rate: DEFAULT_RATE, matched: false };
}

export interface UsageTokens {
  inputTokens: number;
  outputTokens: number;
  cacheCreationInputTokens: number;
  cacheReadInputTokens: number;
}

export function estimateCostUSD(model: string, u: UsageTokens): number {
  const { rate } = rateForModel(model);
  return (
    (u.inputTokens / 1_000_000) * rate.inputPerM +
    (u.outputTokens / 1_000_000) * rate.outputPerM +
    (u.cacheCreationInputTokens / 1_000_000) * rate.cacheWritePerM +
    (u.cacheReadInputTokens / 1_000_000) * rate.cacheReadPerM
  );
}
