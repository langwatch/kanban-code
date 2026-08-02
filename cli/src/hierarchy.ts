import type { Link } from "./types.js";

/** How the sender of a message relates to the receiver in the subagent tree. */
export type SubagentRelationship = "parent" | "subagent";

export function subagentDepth(cardId: string, links: Link[]): number {
  const byId = new Map(links.map((link) => [link.id, link]));
  let current = byId.get(cardId);
  let depth = 0;
  const visited = new Set<string>();
  while (current?.parentCardId && !visited.has(current.id)) {
    visited.add(current.id);
    depth += 1;
    current = byId.get(current.parentCardId);
  }
  return depth;
}

export function ancestorIds(cardId: string, links: Link[]): Set<string> {
  const byId = new Map(links.map((link) => [link.id, link]));
  const result = new Set<string>();
  let current = byId.get(cardId)?.parentCardId;
  while (current && !result.has(current)) {
    result.add(current);
    current = byId.get(current)?.parentCardId;
  }
  return result;
}

export function descendantIds(cardId: string, links: Link[]): Set<string> {
  const childrenByParent = new Map<string, Link[]>();
  for (const link of links) {
    if (!link.parentCardId) continue;
    const children = childrenByParent.get(link.parentCardId) ?? [];
    children.push(link);
    childrenByParent.set(link.parentCardId, children);
  }
  const result = new Set<string>();
  const visited = new Set<string>([cardId]);
  const pending = [cardId];
  while (pending.length > 0) {
    const parentId = pending.pop()!;
    for (const child of childrenByParent.get(parentId) ?? []) {
      if (!visited.has(child.id)) {
        visited.add(child.id);
        result.add(child.id);
        pending.push(child.id);
      }
    }
  }
  return result;
}

/**
 * Relationship of `fromCardId` as seen by `toCardId`, so a delivered message can
 * say whether it came from the agent that owns the receiver or from one of its
 * own subagents.
 */
export function subagentRelationship(
  fromCardId: string | null | undefined,
  toCardId: string | null | undefined,
  links: Link[]
): SubagentRelationship | undefined {
  if (!fromCardId || !toCardId || fromCardId === toCardId) return undefined;
  if (ancestorIds(toCardId, links).has(fromCardId)) return "parent";
  if (ancestorIds(fromCardId, links).has(toCardId)) return "subagent";
  return undefined;
}

export function relationshipLabel(relationship: SubagentRelationship | undefined): string {
  switch (relationship) {
    case "parent":
      return " (parent agent)";
    case "subagent":
      return " (subagent)";
    default:
      return "";
  }
}
