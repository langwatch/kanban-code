import type { ChannelInfo, ChannelMessage } from "./types";

/** Every API call needs the share token, parsed from the current URL's
 *  query string. Token handling is centralized here so no other module
 *  has to think about it. */
export function getToken(): string {
  const params = new URLSearchParams(window.location.search);
  return params.get("token") ?? "";
}

/** Discovery: list of channels the current token has access to. Today the
 *  server returns a single-element array (one share link == one channel),
 *  but the API is shaped as an array so future multi-channel shares can
 *  land without reworking the client. */
export async function fetchAccessibleChannels(): Promise<ChannelInfo[]> {
  const res = await fetch(authedUrl("/api/channels"));
  if (!res.ok) throw new Error(`channels: ${res.status}`);
  const body = (await res.json()) as { channels: ChannelInfo[] };
  return body.channels;
}

export interface SendBody {
  handle: string;
  body: string;
  imagePaths?: string[];
}

function authedUrl(path: string, extraParams: Record<string, string> = {}): string {
  const p = new URLSearchParams({ token: getToken(), ...extraParams });
  return `${path}?${p.toString()}`;
}

export async function fetchInfo(channel: string): Promise<ChannelInfo> {
  const res = await fetch(authedUrl(`/api/channels/${channel}/info`));
  if (!res.ok) throw new Error(`info: ${res.status}`);
  return res.json();
}

export async function fetchHistory(channel: string): Promise<ChannelMessage[]> {
  const res = await fetch(authedUrl(`/api/channels/${channel}/history`));
  if (!res.ok) throw new Error(`history: ${res.status}`);
  const body = (await res.json()) as { messages: ChannelMessage[] };
  return body.messages;
}

export async function sendMessage(channel: string, payload: SendBody): Promise<ChannelMessage> {
  const res = await fetch(authedUrl(`/api/channels/${channel}/send`), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`send failed: ${res.status} ${err}`);
  }
  const body = (await res.json()) as { msg: ChannelMessage };
  return body.msg;
}

export async function uploadImage(channel: string, file: Blob): Promise<string> {
  const res = await fetch(authedUrl(`/api/channels/${channel}/images`), {
    method: "POST",
    headers: { "Content-Type": file.type || "image/png" },
    body: file,
  });
  if (!res.ok) throw new Error(`image upload: ${res.status}`);
  const body = (await res.json()) as { path: string };
  return body.path;
}

/** One long-poll round trip. Server either returns immediately with any
 *  messages newer than `since`, or hangs for ~25 s waiting for the next
 *  append before returning `{ messages: [], lastId: since }`.
 *
 *  The `signal` is the abort hatch for callers (e.g. React unmount) — it
 *  cancels both the in-flight fetch and any server-side hold. */
export interface PollResult { messages: ChannelMessage[]; lastId: string }
export async function pollForMessages(
  channel: string,
  since: string,
  signal: AbortSignal,
): Promise<PollResult> {
  const res = await fetch(
    authedUrl(`/api/channels/${channel}/poll`, since ? { since } : {}),
    { signal },
  );
  if (!res.ok) throw new Error(`poll: ${res.status}`);
  return (await res.json()) as PollResult;
}

/** Turn an absolute image filesystem path (the form stored in the jsonl and
 *  pasted into tmux) into a tokenized HTTP URL the browser can load via
 *  `<img src>`. Returns null when the path doesn't match the expected shape,
 *  which keeps one stray entry from sneaking a broken image into the chat. */
export function imageFilesystemPathToHttpUrl(absPath: string): string | null {
  // Shape: <anything>/channels/images/<msgId>/<filename>
  const m = /[/\\]channels[/\\]images[/\\]([^/\\]+)[/\\]([^/\\]+)$/.exec(absPath);
  if (!m) return null;
  const [, msgId, filename] = m;
  return authedUrl(`/api/images/${msgId}/${filename}`);
}
