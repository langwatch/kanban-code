import type { ChannelMessage, ChannelMessageType } from "../types";

/// Render-time view of a message after applying every Edit/Delete/Reaction
/// row that references it (#113). Pure data — no React, no store.
export interface RenderedMessage {
  id: string;
  ts: string;
  from: ChannelMessage["from"];
  body: string;
  type: ChannelMessageType;
  imagePaths?: string[];
  source?: ChannelMessage["source"];
  mentions?: string[];
  edited: boolean;
  deleted: boolean;
  reactions: ReactionAggregate[];
}

export interface ReactionAggregate {
  emoji: string;
  /// Stable list of handles whose net count for this emoji is currently 1
  /// (toggle semantics: odd-count = on, even-count = off).
  handles: string[];
}

/// Collapses an append-only JSONL into the rendered view.
///
///   - Plain Message / Join / Leave / System rows pass through unchanged.
///   - Edit rows targeting an existing Message override its body; latest Edit wins.
///   - Delete rows targeting an existing Message mark it deleted.
///   - Reaction rows toggle parity per (target_id, emoji, sender) — odd
///     means "currently reacting", even means "removed".
///   - Rows referencing unknown ids are dropped silently (matches the
///     macOS Swift app — keeps render robust against partial logs).
///
/// Output is in the same order Message rows appear in the input.
export function collapseMessages(raw: ChannelMessage[]): RenderedMessage[] {
  const order: string[] = [];
  const byId = new Map<string, RenderedMessage>();
  const reactionParity = new Map<string, Map<string, Map<string, number>>>();

  const ensureReactionMap = (msgId: string) => {
    let perMsg = reactionParity.get(msgId);
    if (!perMsg) {
      perMsg = new Map();
      reactionParity.set(msgId, perMsg);
    }
    return perMsg;
  };

  for (const m of raw) {
    const kind = m.type ?? "message";
    switch (kind) {
      case "message":
      case "join":
      case "leave":
      case "system": {
        if (!byId.has(m.id)) {
          order.push(m.id);
          byId.set(m.id, {
            id: m.id,
            ts: m.ts,
            from: m.from,
            body: m.body,
            type: kind,
            imagePaths: m.imagePaths,
            source: m.source,
            mentions: m.mentions,
            edited: false,
            deleted: false,
            reactions: [],
          });
        }
        break;
      }
      case "edit": {
        const targetId = m.refs?.editsMessageId;
        if (!targetId) break;
        const target = byId.get(targetId);
        if (!target) break;
        target.body = m.body;
        target.mentions = m.mentions ?? target.mentions;
        target.edited = true;
        break;
      }
      case "delete": {
        const targetId = m.refs?.editsMessageId;
        if (!targetId) break;
        const target = byId.get(targetId);
        if (!target) break;
        target.deleted = true;
        break;
      }
      case "reaction": {
        const targetId = m.refs?.reactionTo;
        const emoji = m.refs?.emoji;
        if (!targetId || !emoji) break;
        if (!byId.has(targetId)) break;
        const perEmoji = ensureReactionMap(targetId);
        let perSender = perEmoji.get(emoji);
        if (!perSender) {
          perSender = new Map();
          perEmoji.set(emoji, perSender);
        }
        const handle = m.from.handle;
        perSender.set(handle, (perSender.get(handle) ?? 0) + 1);
        break;
      }
    }
  }

  // Bake reactionParity into target.reactions: keep only odd-count handles,
  // preserve first-occurrence order so the UI is stable across reloads.
  for (const [targetId, perEmoji] of reactionParity) {
    const target = byId.get(targetId);
    if (!target) continue;
    const aggregates: ReactionAggregate[] = [];
    // Walk the input again in order so emoji presentation order is stable.
    const seenEmoji = new Set<string>();
    for (const m of raw) {
      if (m.type !== "reaction") continue;
      if (m.refs?.reactionTo !== targetId) continue;
      const emoji = m.refs?.emoji;
      if (!emoji || seenEmoji.has(emoji)) continue;
      const perSender = perEmoji.get(emoji);
      if (!perSender) continue;
      const handles: string[] = [];
      // First-occurrence order of senders for this emoji.
      const senderSeen = new Set<string>();
      for (const m2 of raw) {
        if (m2.type !== "reaction") continue;
        if (m2.refs?.reactionTo !== targetId) continue;
        if (m2.refs?.emoji !== emoji) continue;
        if (senderSeen.has(m2.from.handle)) continue;
        senderSeen.add(m2.from.handle);
        if ((perSender.get(m2.from.handle) ?? 0) % 2 === 1) {
          handles.push(m2.from.handle);
        }
      }
      if (handles.length > 0) {
        aggregates.push({ emoji, handles });
      }
      seenEmoji.add(emoji);
    }
    target.reactions = aggregates;
  }

  return order.map((id) => byId.get(id)!).filter(Boolean);
}

/// Splits a message body into runs of text and mention spans. Used to
/// pretty-print `@handle` references in MessageRow without mutating the
/// underlying stored body.
export type BodyToken =
  | { kind: "text"; value: string }
  | { kind: "mention"; handle: string };

const MENTION_RE = /@([A-Za-z0-9_-]+)/g;

export function tokenizeBody(body: string): BodyToken[] {
  const out: BodyToken[] = [];
  let last = 0;
  for (const m of body.matchAll(MENTION_RE)) {
    const idx = m.index ?? 0;
    if (idx > last) out.push({ kind: "text", value: body.slice(last, idx) });
    out.push({ kind: "mention", handle: m[1] });
    last = idx + m[0].length;
  }
  if (last < body.length) out.push({ kind: "text", value: body.slice(last) });
  return out;
}
