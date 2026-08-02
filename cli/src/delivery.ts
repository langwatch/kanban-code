/**
 * How a message reaches an agent.
 *
 * The same three semantics back `kanban send --mode` and the self-compact
 * threshold actions, so a rule that says "interrupt" and a command that says
 * `--mode interrupt` do exactly the same thing.
 */
export type DeliveryMode = "steer" | "queue" | "interrupt";

export const DELIVERY_MODES: DeliveryMode[] = ["steer", "queue", "interrupt"];

/** `enqueue` reads more naturally to some callers, so both spellings work. */
export function parseDeliveryMode(raw: string | undefined): DeliveryMode {
  const value = (raw ?? "steer").trim().toLowerCase();
  if (value === "enqueue") return "queue";
  if ((DELIVERY_MODES as string[]).includes(value)) return value as DeliveryMode;
  throw new Error(`Invalid --mode "${raw}". Use steer (default), queue, or interrupt.`);
}
