import {
  writeFileSync,
  mkdirSync,
  existsSync,
  copyFileSync,
  readdirSync,
  unlinkSync,
  renameSync,
} from "node:fs";
import { dirname, basename, join } from "node:path";
import { linksPath } from "./paths.js";
import { readLinks } from "./data.js";
import { Link } from "./types.js";

/// ISO-8601 timestamp without milliseconds, matching Swift's `.iso8601`
/// encoding ("2026-04-25T12:02:24Z") so headless writes diff cleanly against
/// app writes.
export function isoNow(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

/// Deterministic, key-sorted, pretty JSON matching Swift's
/// `[.prettyPrinted, .sortedKeys]` output (2-space indent, no trailing newline).
function sortValue(value: any): any {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value && typeof value === "object") {
    const out: Record<string, any> = {};
    for (const key of Object.keys(value).sort()) out[key] = sortValue(value[key]);
    return out;
  }
  return value;
}

export function sortedStringify(obj: any): string {
  return JSON.stringify(sortValue(obj), null, 2);
}

/// Write all links atomically to links.json, keeping a rolling 7-day set of
/// daily backups (mirrors CoordinationStore.writeLinks).
export function writeLinks(links: Link[]): void {
  const file = linksPath();
  mkdirSync(dirname(file), { recursive: true });
  rotateDailyBackup(file);

  const tmp = `${file}.tmp`;
  writeFileSync(tmp, sortedStringify({ links }));
  renameSync(tmp, file); // atomic replace on POSIX
}

const DAILY_BACKUP_RETENTION = 7;

function rotateDailyBackup(file: string): void {
  if (!existsSync(file)) return;
  try {
    const today = new Date().toISOString().slice(0, 10); // UTC YYYY-MM-DD
    const todayPath = `${file}.daily-${today}.bak`;
    if (!existsSync(todayPath)) copyFileSync(file, todayPath);

    const dir = dirname(file);
    const prefix = `${basename(file)}.daily-`;
    const snapshots = readdirSync(dir)
      .filter((f) => f.startsWith(prefix) && f.endsWith(".bak"))
      .sort(); // alphabetical == chronological for YYYY-MM-DD
    for (const old of snapshots.slice(0, -DAILY_BACKUP_RETENTION)) {
      try {
        unlinkSync(join(dir, old));
      } catch {
        /* a backup must never block a write */
      }
    }
  } catch {
    /* a backup must never block a write */
  }
}

/// Upsert a link by id: replace if present, append otherwise.
export function upsertCard(card: Link): void {
  const links = readLinks();
  const index = links.findIndex((l) => l.id === card.id);
  if (index >= 0) links[index] = card;
  else links.push(card);
  writeLinks(links);
}

/// Find the existing card for an agent slug (matched by name), if any.
export function findCardByName(name: string): Link | undefined {
  return readLinks().find((l) => l.name === name);
}
