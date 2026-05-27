import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome } from "../paths.js";

/// "Received user message" is mirrored to Slack when the agent's
/// UserPromptSubmit hook confirms a prompt was actually received (see the
/// daemon). A human's Slack message relayed in by the bridge would also fire
/// UserPromptSubmit, but it already appears in the channel as that person's
/// message, so it must NOT be echoed. The bridge drops a skip-announce marker
/// here right before it pastes a relay; the daemon consumes one marker per
/// confirmed prompt and skips that announce.
///
/// Markers carry a timestamp and expire by TTL: if a relayed prompt never
/// actually gets submitted (e.g. the paste was lost), its marker is dropped
/// rather than silently suppressing a later automated prompt's announce.

/// How long a skip-announce marker stays valid. Generous on purpose: a relay
/// pasted while the agent is busy only fires UserPromptSubmit once the agent
/// picks it up, which can be a while; we still want that echo suppressed.
export const ANNOUNCE_SUPPRESS_TTL_MS = 10 * 60 * 1000;

export interface SuppressMarker {
  sessionId: string;
  ts: number;
}

export function announceSuppressPath(): string {
  return join(kanbanHome(), "announce-suppress.jsonl");
}

/// Record a skip-announce marker for a session. Append-only so the writer (the
/// bridge) never races the reader (the daemon), which tails by byte offset.
export function recordAnnounceSuppress(sessionId: string, now = Date.now()): void {
  if (!sessionId) return;
  const path = announceSuppressPath();
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify({ sessionId, ts: now } satisfies SuppressMarker) + "\n");
}
