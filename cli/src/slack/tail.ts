import { statSync } from "node:fs";

/// Where the bridge reads one agent's transcript: the current file, the byte
/// offset in it, when it started following that file, and the offsets of
/// every file it followed before, so switching back resumes instead of
/// rereading from byte 0.
export interface TailCursor {
  path?: string;
  offset: number;
  followedSinceMs: number;
  offsets: Map<string, number>;
}

/// More posts than this in one poll is a replayed backlog, not live activity.
export const MAX_POSTS_PER_POLL = 20;

/// File timestamps come from a coarser clock than Date.now().
const BIRTH_CLOCK_SLACK_MS = 1000;

export function newTailCursor({ path, nowMs = Date.now() }: { path?: string; nowMs?: number }): TailCursor {
  return { path, offset: path ? sizeOf(path) : 0, followedSinceMs: nowMs, offsets: new Map() };
}

function sizeOf(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

function birthOf(path: string): number {
  try {
    return statSync(path).birthtimeMs || 0;
  } catch {
    return 0;
  }
}

/// Switch the cursor to `latest` when it differs from the current file.
/// A file followed before resumes at its saved offset. A file created after
/// the bridge started following the current one is a fresh session and is
/// read from its start. Any other file already existed: start at its end.
export function switchTail({ cursor, latest, nowMs = Date.now() }: { cursor: TailCursor; latest?: string; nowMs?: number }): boolean {
  if (!latest || latest === cursor.path) return false;
  if (cursor.path) cursor.offsets.set(cursor.path, cursor.offset);
  const saved = cursor.offsets.get(latest);
  let offset: number;
  if (saved !== undefined) offset = saved;
  else {
    const born = birthOf(latest);
    offset = born > 0 && born >= cursor.followedSinceMs - BIRTH_CLOCK_SLACK_MS ? 0 : sizeOf(latest);
  }
  cursor.path = latest;
  cursor.offset = offset;
  cursor.followedSinceMs = nowMs;
  return true;
}

/// Posts to send for one poll. Over the cap, the batch is a backlog: send one
/// notice instead of replaying it.
export function capPosts<T extends { kind: string; text: string }>(
  posts: T[],
  makeNotice: (text: string) => T,
  max = MAX_POSTS_PER_POLL,
): T[] {
  if (posts.length <= max) return posts;
  return [makeNotice(`skipped ${posts.length} old lines`)];
}
