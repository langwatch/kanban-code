/** `kv owner` and `kv audit check`: the owner keys and the audit log check. */

export interface OwnerStatus {
  active: boolean;
  keys: Array<{ name: string; kind: string; fingerprint: string; addedAt: string }>;
  sealed: number;
  plain: number;
}

export interface AuditReport {
  machine: string;
  logs: Array<{ name: string; lines: number; unchained: number; breaks: number[] }>;
  missing: Array<{ machine: string; count: number; samples: string[]; notMirroredYet: number }>;
  unrecordedApprovals: string[];
  notes: string[];
}

export function ownerLines(s: OwnerStatus): string[] {
  const lines: string[] = [];
  if (s.keys.length === 0) {
    lines.push("no owner keys: set them up in Kanban Code on the Mac, Settings > Vault > Owner Keys");
  }
  for (const k of s.keys) lines.push(`${k.kind.padEnd(8)} ${k.fingerprint}  ${k.name}`);
  lines.push(
    s.active
      ? `${s.sealed} ask/never secrets open only on those keys` + (s.plain > 0 ? `, ${s.plain} still wait to be sealed` : "")
      : `not sealing yet (needs a device key and the recovery key): ${s.plain} ask/never secrets are readable with the machine key`
  );
  return lines;
}

export function auditProblems(r: AuditReport): number {
  return (
    r.logs.reduce((n, l) => n + l.breaks.length, 0) +
    r.missing.reduce((n, m) => n + m.count, 0) +
    r.unrecordedApprovals.length
  );
}

export function auditLines(r: AuditReport): string[] {
  const lines: string[] = [];
  for (const l of r.logs) {
    const old = l.unchained > 0 ? `, ${l.unchained} from before the chain` : "";
    lines.push(
      l.breaks.length === 0
        ? `ok      ${l.name}: ${l.lines} lines${old}`
        : `BROKEN  ${l.name}: the chain breaks at line ${l.breaks.slice(0, 10).join(", ")}${l.breaks.length > 10 ? "..." : ""} (${l.lines} lines${old})`
    );
  }
  for (const m of r.missing) {
    const waiting = m.notMirroredYet > 0 ? ` (${m.notMirroredYet} of its lines not mirrored here yet)` : "";
    if (m.count === 0) {
      lines.push(`ok      ${m.machine}: every line mirrored here is still in its log${waiting}`);
    } else {
      lines.push(`MISSING ${m.machine}: ${m.count} lines mirrored here are gone from its log${waiting}`);
      for (const sample of m.samples) lines.push(`          ${sample.slice(0, 300)}`);
    }
  }
  for (const a of r.unrecordedApprovals) lines.push(`UNRECORDED approval this device has no record of: ${a}`);
  for (const n of r.notes) lines.push(`note    ${n}`);
  const problems = auditProblems(r);
  lines.push(problems === 0 ? "no broken chain, nothing missing" : `${problems} problem${problems === 1 ? "" : "s"}`);
  return lines;
}
