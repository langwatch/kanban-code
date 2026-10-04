/**
 * `kv scrub`: runs and reports the secret scrubber of this machine's master
 * (docs/vault.md, "Scrubber"). Everything printed is names, paths and counts.
 */

import { resolve } from "node:path";

export interface ScrubFileReport {
  path: string;
  known: number;
  new: number;
  live?: boolean;
  error?: string;
}

export interface ScrubReport {
  machine: string;
  startedAt: string;
  finishedAt: string;
  dryRun: boolean;
  filesSeen: number;
  filesScanned: number;
  filesUnchanged: number;
  filesLive: number;
  bytesScanned: number;
  filesWithSecrets: number;
  replacements: number;
  newSecrets: number;
  skipped: number;
  bySecret: Record<string, number>;
  byFolder: Record<string, number>;
  files: ScrubFileReport[];
  errors: string[];
  backupPath?: string;
  backupFiles?: number;
  note?: string;
}

export type ScrubPatterns = "on" | "off" | "typed";

export interface ScrubStatus {
  machine: string;
  schedule: { enabled: boolean; hour: number; minute: number; paths?: string[]; patterns?: ScrubPatterns | boolean };
  running: boolean;
  progress?: string;
  nextRun?: string;
  lastRun?: ScrubReport;
  lastDryRun?: ScrubReport;
}

export interface ScrubClient {
  call<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }>;
}

const two = (n: number) => String(n).padStart(2, "0");

function top(counts: Record<string, number>, limit: number): Array<[string, number]> {
  return Object.entries(counts)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit);
}

export function formatScrubReport(r: ScrubReport, limit = 15): string {
  const seconds = Math.round((Date.parse(r.finishedAt) - Date.parse(r.startedAt)) / 1000);
  const lines: string[] = [];
  const verb = r.dryRun ? "would replace" : "replaced";
  lines.push(`${r.machine}: ${r.dryRun ? "dry run" : "run"} of ${r.startedAt.slice(0, 16)}Z, ${seconds}s`);
  if (r.note) lines.push(`  ${r.note}`);
  lines.push(
    `  files: ${r.filesSeen} seen, ${r.filesScanned} scanned (${(r.bytesScanned / 2 ** 30).toFixed(2)} GiB), ` +
      `${r.filesUnchanged} unchanged since the last run, ${r.filesLive} live`
  );
  lines.push(
    `  ${verb} ${r.replacements} values in ${r.filesWithSecrets} files; ` +
      `${r.newSecrets} not in the vault ${r.dryRun ? "(a run saves them under scrubbed/found/)" : "saved under scrubbed/found/"}; ` +
      `${r.skipped} left in place`
  );
  if (r.backupPath) lines.push(`  backup: what was replaced in ${r.backupFiles ?? 0} files, in ${r.backupPath} (deleted after 7 days)`);
  const folders = top(r.byFolder, limit);
  if (folders.length) {
    lines.push("  by folder:");
    for (const [name, n] of folders) lines.push(`    ${String(n).padStart(7)}  ${name}`);
  }
  const secrets = top(r.bySecret, limit);
  if (secrets.length) {
    lines.push(`  by secret (${Object.keys(r.bySecret).length} names):`);
    for (const [name, n] of secrets) lines.push(`    ${String(n).padStart(7)}  ${name}`);
  }
  if (r.errors.length) {
    lines.push(`  errors (${r.errors.length}):`);
    for (const e of r.errors.slice(0, limit)) lines.push(`    ${e}`);
  }
  return lines.join("\n") + "\n";
}

export function formatScrubStatus(s: ScrubStatus): string {
  const lines = [
    `${s.machine}: scrubber ${s.schedule.enabled ? `on, daily at ${two(s.schedule.hour)}:${two(s.schedule.minute)}` : "off"}` +
      (s.running ? `, running (${s.progress ?? "starting"})` : ""),
  ];
  const patterns = s.schedule.patterns;
  if (patterns === false || patterns === "off") lines.push("  format patterns off: only values the vault holds are replaced");
  if (patterns === true || patterns === "on") lines.push("  format patterns on: every key in a vendor's format is saved and replaced");
  if (s.schedule.paths?.length) lines.push(`  extra paths: ${s.schedule.paths.join(", ")}`);
  let text = lines.join("\n") + "\n";
  if (s.lastRun) text += formatScrubReport(s.lastRun, 5);
  else text += "  no run yet\n";
  return text;
}

/** `kv scrub [--dry-run] [--once on|typed|off [--except VENDOR,...]] [--status] [--json] [--all] | --at HH:MM | --on | --off | --add PATH | --remove PATH | --patterns typed|on|off | --restore FILE...` */
export async function runScrub(
  args: string[],
  client: ScrubClient,
  out: (text: string) => void,
  sleep: (ms: number) => Promise<void>
): Promise<number> {
  const has = (flag: string) => {
    const i = args.indexOf(flag);
    if (i < 0) return false;
    args.splice(i, 1);
    return true;
  };
  const json = has("--json");
  const all = has("--all");
  const status = async () => (await client.call<ScrubStatus>("GET", "../scrub/status")).body;

  const at = args.indexOf("--at");
  const on = has("--on");
  const off = has("--off");
  const add = args.indexOf("--add");
  const remove = args.indexOf("--remove");
  const patterns = args.indexOf("--patterns");
  if (patterns >= 0 && !["on", "off", "typed"].includes(args[patterns + 1] ?? "")) throw new Error("kv scrub --patterns typed|on|off");
  if (at >= 0 || on || off || add >= 0 || remove >= 0 || patterns >= 0) {
    const current = (await status()).schedule;
    const next = { ...current, paths: [...(current.paths ?? [])] };
    for (const [i, flag] of [[add, "--add"], [remove, "--remove"]] as const) {
      if (i < 0) continue;
      const path = args[i + 1];
      if (!path || path.startsWith("--")) throw new Error(`kv scrub ${flag} <file or folder>`);
      next.paths = next.paths.filter((p) => p !== path);
      if (flag === "--add") next.paths.push(path);
    }
    if (at >= 0) {
      const m = /^(\d{1,2}):(\d{2})$/.exec(args[at + 1] ?? "");
      if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) throw new Error("kv scrub --at HH:MM");
      next.hour = Number(m[1]);
      next.minute = Number(m[2]);
    }
    if (patterns >= 0) next.patterns = args[patterns + 1] as ScrubPatterns;
    if (on) next.enabled = true;
    if (off) next.enabled = false;
    const { body } = await client.call<ScrubStatus>("PUT", "../scrub/schedule", next);
    out(json ? JSON.stringify(body, null, 2) + "\n" : formatScrubStatus(body));
    return 0;
  }

  const restore = args.indexOf("--restore");
  if (restore >= 0) {
    const paths = args.slice(restore + 1).filter((a) => !a.startsWith("--")).map((a) => resolve(a));
    const everything = args.includes("--all-files");
    if (!paths.length && !everything) throw new Error("kv scrub --restore <file>... | --restore --all-files");
    const { body } = await client.call<{ files: number; errors: string[] }>(
      "POST",
      "../scrub/restore",
      everything ? { all: true } : { paths }
    );
    if (json) out(JSON.stringify(body, null, 2) + "\n");
    else {
      out(`restored ${body.files} file${body.files === 1 ? "" : "s"}\n`);
      for (const e of body.errors) out(`  ${e}\n`);
    }
    return body.errors.length ? 1 : 0;
  }

  if (has("--status")) {
    const s = await status();
    out(json ? JSON.stringify(s, null, 2) + "\n" : formatScrubStatus(s));
    return 0;
  }

  const dryRun = has("--dry-run");
  const run: { dryRun: boolean; patterns?: ScrubPatterns; except?: string[] } = { dryRun };
  const once = args.indexOf("--once");
  const except = args.indexOf("--except");
  if (once >= 0) {
    const mode = args[once + 1] ?? "";
    if (!["on", "off", "typed"].includes(mode)) throw new Error("kv scrub --once on|typed|off [--except VENDOR,...]");
    run.patterns = mode as ScrubPatterns;
  }
  if (except >= 0) {
    const names = (args[except + 1] ?? "").split(",").map((n) => n.trim()).filter(Boolean);
    if (once < 0 || !names.length || names.some((n) => n.startsWith("--"))) {
      throw new Error("kv scrub --once on --except VENDOR[,VENDOR] (vendor names as the finds are named, e.g. LANGWATCH_API_KEY)");
    }
    run.except = names;
  }
  const started = await client.call<ScrubStatus & { error?: string }>("POST", "../scrub/run", run);
  if (started.status >= 400) {
    out(`kv: ${started.body.error ?? `the master answered ${started.status}`}\n`);
    return 1;
  }
  let s = await status();
  while (s.running) {
    await sleep(2000);
    s = await status();
  }
  const report = dryRun ? s.lastDryRun : s.lastRun;
  if (!report) {
    out("kv: the run left no report\n");
    return 1;
  }
  out(json ? JSON.stringify(report, null, 2) + "\n" : formatScrubReport(report, all ? 10_000 : 15));
  return 0;
}
