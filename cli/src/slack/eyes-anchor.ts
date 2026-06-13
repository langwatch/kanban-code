import { mkdirSync, writeFileSync, readFileSync, renameSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome } from "../paths.js";

/// On-disk record of the 👀 ack message the bridge posts in an agent's
/// channel the moment a Slack human relays a prompt. Slack's
/// assistant.threads.setStatus only attaches to thread roots authored by
/// the app itself, so we need an app-owned anchor for the "is working…"
/// pill. The 👀 also gives the channel a visible "received" beat in the
/// 10-20s gap before the agent's first reply.
///
/// We delete the eyes once the agent posts its first text reply (the new
/// thread root takes over as the pill anchor). The persisted record lets a
/// bridge restart between the eyes post and the agent's first reply still
/// finish the cleanup — without it the eyes would orphan in the channel.
///
/// Same atomic write pattern as active-pill / thread-root.

export interface PersistedEyesAnchor {
  channelId: string;
  /// ts of the bot's 👀 message; what we pass to chat.delete + setStatus.
  ts: string;
}

function eyesPath(slug: string): string {
  return join(kanbanHome(), "eyes-anchors", slug);
}

export function writeEyesAnchor(slug: string, anchor: PersistedEyesAnchor): void {
  if (!slug) return;
  const path = eyesPath(slug);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(anchor));
  renameSync(tmp, path);
}

export function readEyesAnchor(slug: string): PersistedEyesAnchor | undefined {
  try {
    const raw = readFileSync(eyesPath(slug), "utf-8");
    const parsed = JSON.parse(raw) as Partial<PersistedEyesAnchor>;
    if (!parsed.channelId || !parsed.ts) return undefined;
    return parsed as PersistedEyesAnchor;
  } catch {
    return undefined;
  }
}

export function clearEyesAnchor(slug: string): void {
  if (!slug) return;
  try {
    unlinkSync(eyesPath(slug));
  } catch {
    /* file may not exist — that's fine */
  }
}
