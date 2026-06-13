//! K-Sortable Unique Identifier — bit-for-bit port of
//! `Sources/KanbanCodeCore/Infrastructure/KSUID.swift`.
//!
//! Format: 4-byte big-endian timestamp (seconds since 2014-05-13 16:53:20 UTC,
//! i.e. unix 1_400_000_000) + 16 random bytes = 20 bytes, base62-encoded with
//! the alphabet `0..9A..Za..z` into a fixed 27-character string. With an
//! optional `<prefix>_` (e.g. `card_2MtCMwXZOHPSlEMDe7OYW6bRfXX`).
//!
//! IDs sort chronologically as plain strings, which is why the macOS app uses
//! them — the kanban CLI and links.json inspection benefit from chronological
//! `card_…` ordering. Keeping the format identical means links.json stays
//! byte-compatible across the two ports.

use std::time::{SystemTime, UNIX_EPOCH};

use rand::RngCore;

/// KSUID epoch: 2014-05-13T16:53:20Z (1_400_000_000 unix seconds).
const KSUID_EPOCH: u32 = 1_400_000_000;
const BASE62_ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ENCODED_LEN: usize = 27;

/// Generate a 27-character KSUID. Pass `Some("card")` to get `card_<27 chars>`.
pub fn generate(prefix: Option<&str>) -> String {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as u32)
        .unwrap_or(KSUID_EPOCH);
    let ts = now_secs.saturating_sub(KSUID_EPOCH);

    let mut bytes = [0u8; 20];
    bytes[0] = ((ts >> 24) & 0xFF) as u8;
    bytes[1] = ((ts >> 16) & 0xFF) as u8;
    bytes[2] = ((ts >> 8) & 0xFF) as u8;
    bytes[3] = (ts & 0xFF) as u8;
    rand::thread_rng().fill_bytes(&mut bytes[4..]);

    let encoded = base62_encode(&bytes);
    match prefix {
        Some(p) => format!("{p}_{encoded}"),
        None => encoded,
    }
}

/// Base62-encode a 20-byte big-endian integer into a fixed 27-character string.
/// Mirrors the Swift implementation: repeatedly divide the digit array by 62,
/// writing the remainder into the output from right to left.
fn base62_encode(input: &[u8]) -> String {
    debug_assert_eq!(input.len(), 20, "KSUID payload must be 20 bytes");

    // Mutable copy used as a base-256 big-endian integer.
    let mut number = input.to_vec();
    let mut out = [b'0'; ENCODED_LEN];

    for slot in out.iter_mut().rev() {
        let mut remainder: u16 = 0;
        for digit in number.iter_mut() {
            let value: u16 = (*digit as u16) + remainder * 256;
            *digit = (value / 62) as u8;
            remainder = value % 62;
        }
        *slot = BASE62_ALPHABET[remainder as usize];
    }

    // SAFETY: every byte we wrote came from BASE62_ALPHABET (ASCII).
    String::from_utf8(out.to_vec()).expect("base62 output is ASCII")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_to_27_chars_with_prefix() {
        let id = generate(Some("card"));
        assert!(id.starts_with("card_"));
        assert_eq!(id.len(), "card_".len() + ENCODED_LEN);
        // Body uses only base62 alphabet.
        assert!(id["card_".len()..].bytes().all(|b| BASE62_ALPHABET.contains(&b)));
    }

    #[test]
    fn encodes_to_27_chars_without_prefix() {
        let id = generate(None);
        assert_eq!(id.len(), ENCODED_LEN);
    }

    #[test]
    fn known_zero_payload_round_trip() {
        // Zero in => 27 '0' chars out. Sanity-checks the base62 division loop.
        let zeros = [0u8; 20];
        assert_eq!(base62_encode(&zeros), "0".repeat(ENCODED_LEN));
    }
}
