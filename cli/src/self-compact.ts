/** How a threshold message reaches the agent. Mirrors `kanban send --mode`. */
export type SelfCompactAction = "queuePrompt" | "steer" | "interrupt";

export interface SelfCompactRule {
  thresholdTokens: number;
  action: SelfCompactAction;
  message: string;
}

export const STEER_COMPACT_OFFSET_TOKENS = 100_000;
export const FORCED_COMPACT_OFFSET_TOKENS = 200_000;

export const DEFAULT_SELF_COMPACT_RULES: SelfCompactRule[] = [
  { thresholdTokens: 500_000, action: "queuePrompt", message: "You are above the 500k context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact." },
  { thresholdTokens: 600_000, action: "queuePrompt", message: "You are above the 600k context limit. Please compact yourself soon using the kanban CLI self-compact command." },
  { thresholdTokens: 700_000, action: "steer", message: "You are above the 700k context limit. Compact yourself IMMEDIATELY using the kanban CLI self-compact command." },
  { thresholdTokens: 750_000, action: "interrupt", message: "/compact" },
];

/**
 * Settings saved before steering and interrupting were separate modes spell the
 * steering action `compactNow`.
 */
export function normalizeSelfCompactAction(raw: string | undefined): SelfCompactAction {
  if (raw === "compactNow") return "steer";
  if (raw === "queuePrompt" || raw === "steer" || raw === "interrupt") return raw;
  return "queuePrompt";
}

export function normalizeSelfCompactRules(rules: SelfCompactRule[]): SelfCompactRule[] {
  return rules.map((rule) => ({ ...rule, action: normalizeSelfCompactAction(rule.action) }));
}

export function parseContextThreshold(raw: string): number {
  const value = raw.trim();
  const match = /^(\d+)(k)?$/i.exec(value);
  if (!match) {
    throw new Error(`Invalid context threshold "${raw}". Use a positive token count such as 250k or 250000.`);
  }

  const base = Number(match[1]);
  const tokens = match[2] ? base * 1_000 : base;
  if (!Number.isSafeInteger(tokens) || tokens <= 0 || tokens > Number.MAX_SAFE_INTEGER - FORCED_COMPACT_OFFSET_TOKENS) {
    throw new Error(`Invalid context threshold "${raw}". Use a positive token count such as 250k or 250000.`);
  }
  return tokens;
}

export function tokenLabel(tokens: number): string {
  return tokens % 1_000 === 0 ? `${tokens / 1_000}k` : String(tokens);
}

export function cardSelfCompactRules(thresholdTokens: number): SelfCompactRule[] {
  if (!Number.isSafeInteger(thresholdTokens) || thresholdTokens <= 0 || thresholdTokens > Number.MAX_SAFE_INTEGER - FORCED_COMPACT_OFFSET_TOKENS) {
    return [];
  }
  // Same escalation as the global defaults: ask while the agent can choose its
  // own moment, steer once it is overdue, interrupt when it is not stopping.
  const steerThreshold = thresholdTokens + STEER_COMPACT_OFFSET_TOKENS;
  return [
    {
      thresholdTokens,
      action: "queuePrompt",
      message: `You are above the ${tokenLabel(thresholdTokens)} context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact, passing an argument for the post-compact message on how to continue.`,
    },
    {
      thresholdTokens: steerThreshold,
      action: "steer",
      message: `You are above the ${tokenLabel(steerThreshold)} context limit. Compact yourself now with the kanban CLI self-compact command, passing an argument for the post-compact message on how to continue.`,
    },
    {
      thresholdTokens: thresholdTokens + FORCED_COMPACT_OFFSET_TOKENS,
      action: "interrupt",
      message: "/compact",
    },
  ];
}

export function effectiveSelfCompactRules(
  cardThresholdTokens: number | undefined,
  globalEnabled: boolean,
  globalRules: SelfCompactRule[]
): SelfCompactRule[] {
  if (cardThresholdTokens !== undefined) {
    return cardSelfCompactRules(cardThresholdTokens);
  }
  if (!globalEnabled) return [];
  return normalizeSelfCompactRules(globalRules)
    .filter((rule) => rule.thresholdTokens > 0)
    .sort((a, b) => a.thresholdTokens - b.thresholdTokens);
}

export function selfCompactPolicySignature(rules: SelfCompactRule[]): string {
  return rules.map((rule) => `${rule.thresholdTokens}:${rule.action}:${rule.message}`).join("|");
}
