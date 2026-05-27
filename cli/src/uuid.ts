import { createHash } from "node:crypto";

/// Namespace for deriving deterministic agent session ids. Fixed forever so a
/// given agent slug always maps to the same Claude session UUID.
export const AGENT_UUID_NAMESPACE = "b0c0ffee-a9e0-5e1d-9c0a-1a2b3c4d5e6f";

function parseUuid(uuid: string): Buffer {
  const hex = uuid.replace(/-/g, "");
  if (hex.length !== 32) throw new Error(`Invalid UUID: ${uuid}`);
  return Buffer.from(hex, "hex");
}

function formatUuid(bytes: Buffer): string {
  const hex = bytes.toString("hex");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

/// RFC 4122 v5 (SHA-1, name-based) UUID. Deterministic: same name + namespace
/// always yields the same UUID.
export function uuidv5(name: string, namespace = AGENT_UUID_NAMESPACE): string {
  const ns = parseUuid(namespace);
  const hash = createHash("sha1")
    .update(ns)
    .update(Buffer.from(name, "utf8"))
    .digest();
  const bytes = Buffer.from(hash.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  return formatUuid(bytes);
}
