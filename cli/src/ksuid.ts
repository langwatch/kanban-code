import { randomBytes } from "node:crypto";

/// Lightweight KSUID (K-Sortable Unique Identifier) generator, matching the
/// Swift implementation in KanbanCodeCore so headless-written cards share the
/// same id format as app-written ones.
///
/// Format: 4-byte big-endian timestamp (seconds since the KSUID epoch
/// 2014-05-13) + 16-byte random payload, base62-encoded to 27 characters.
const EPOCH = 1_400_000_000;
const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ENCODED_LENGTH = 27;

export function generateKsuid(prefix?: string): string {
  const timestamp = Math.floor(Date.now() / 1000) - EPOCH;

  const bytes = new Uint8Array(20);
  bytes[0] = (timestamp >>> 24) & 0xff;
  bytes[1] = (timestamp >>> 16) & 0xff;
  bytes[2] = (timestamp >>> 8) & 0xff;
  bytes[3] = timestamp & 0xff;
  const rand = randomBytes(16);
  bytes.set(rand, 4);

  const encoded = base62Encode(bytes);
  return prefix ? `${prefix}_${encoded}` : encoded;
}

/// Base62-encode a 20-byte array into a fixed 27-character string using
/// big-endian arithmetic division (mirrors the Swift implementation).
function base62Encode(input: Uint8Array): string {
  const number = Array.from(input);
  const result: string[] = new Array(ENCODED_LENGTH).fill("0");

  for (let i = ENCODED_LENGTH - 1; i >= 0; i--) {
    let remainder = 0;
    for (let j = 0; j < number.length; j++) {
      const value = number[j] + remainder * 256;
      number[j] = Math.floor(value / 62);
      remainder = value % 62;
    }
    result[i] = BASE62[remainder];
  }

  return result.join("");
}
