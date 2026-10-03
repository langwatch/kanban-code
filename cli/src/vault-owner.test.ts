import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { auditLines, auditProblems, ownerLines, type AuditReport } from "./vault-owner.js";

const clean: AuditReport = {
  machine: "Mac",
  logs: [
    { name: "this machine (Mac)", lines: 10, unchained: 4, breaks: [] },
    { name: "mirror of box", lines: 7, unchained: 0, breaks: [] },
  ],
  missing: [{ machine: "box", count: 0, samples: [], notMirroredYet: 2 }],
  unrecordedApprovals: [],
  notes: [],
};

describe("kv audit check", () => {
  it("says so when nothing is wrong", () => {
    assert.equal(auditProblems(clean), 0);
    const lines = auditLines(clean);
    assert.equal(lines[0], "ok      this machine (Mac): 10 lines, 4 from before the chain");
    assert.ok(lines[2].includes("2 of its lines not mirrored here yet"));
    assert.equal(lines.at(-1), "no broken chain, nothing missing");
  });

  it("counts a broken chain, lines missing on the box and an unrecorded approval", () => {
    const bad: AuditReport = {
      ...clean,
      logs: [{ name: "mirror of box", lines: 7, unchained: 0, breaks: [5] }],
      missing: [{ machine: "box", count: 2, samples: ['{"secret":"C"}'], notMirroredYet: 0 }],
      unrecordedApprovals: ["2026-10-03T10:00:00.000Z box STRIPE (vault_x)"],
    };
    assert.equal(auditProblems(bad), 4);
    const text = auditLines(bad).join("\n");
    assert.ok(text.includes("BROKEN  mirror of box: the chain breaks at line 5"));
    assert.ok(text.includes("MISSING box: 2 lines mirrored here are gone from its log"));
    assert.ok(text.includes('{"secret":"C"}'));
    assert.ok(text.includes("UNRECORDED approval"));
    assert.ok(text.includes("4 problems"));
  });
});

describe("kv owner", () => {
  it("lists the keys by fingerprint and what is sealed", () => {
    const lines = ownerLines({
      active: true,
      keys: [
        { name: "Mac", kind: "mac", fingerprint: "aaaa bbbb cccc dddd", addedAt: "" },
        { name: "Recovery key", kind: "recovery", fingerprint: "1111 2222 3333 4444", addedAt: "" },
      ],
      sealed: 21,
      plain: 0,
    });
    assert.deepEqual(lines, [
      "mac      aaaa bbbb cccc dddd  Mac",
      "recovery 1111 2222 3333 4444  Recovery key",
      "21 ask/never secrets open only on those keys",
    ]);
  });

  it("says when nothing is sealed yet", () => {
    assert.ok(
      ownerLines({ active: false, keys: [], sealed: 0, plain: 21 })
        .join("\n")
        .includes("21 ask/never secrets are readable with the machine key")
    );
  });
});
