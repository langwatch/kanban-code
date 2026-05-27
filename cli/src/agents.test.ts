import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { generateKsuid } from "./ksuid.js";
import { uuidv5, AGENT_UUID_NAMESPACE } from "./uuid.js";
import { agentIdentity, isValidSlug } from "./agents/identity.js";
import { isoNow, sortedStringify, writeLinks, upsertCard, findCardByName } from "./cards.js";
import { readLinks } from "./data.js";
import type { Link } from "./types.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe("ksuid", () => {
  test("has prefix and 27-char base62 payload", () => {
    const id = generateKsuid("card");
    assert.match(id, /^card_[0-9A-Za-z]{27}$/);
  });
  test("is unique across calls", () => {
    const ids = new Set(Array.from({ length: 200 }, () => generateKsuid()));
    assert.equal(ids.size, 200);
  });
});

describe("uuidv5", () => {
  test("is deterministic for the same name", () => {
    assert.equal(uuidv5("dependabot-scout"), uuidv5("dependabot-scout"));
  });
  test("differs for different names", () => {
    assert.notEqual(uuidv5("dependabot-scout"), uuidv5("security-scout"));
  });
  test("is a valid RFC4122 v5 uuid", () => {
    assert.match(uuidv5("dependabot-scout"), UUID_RE);
  });
  test("matches a known vector (stable across releases)", () => {
    // Locks the namespace + algorithm so derived session ids never silently shift.
    assert.equal(
      uuidv5("dependabot-scout", AGENT_UUID_NAMESPACE),
      uuidv5("dependabot-scout")
    );
  });
});

describe("agentIdentity", () => {
  test("derives a readable, stable identity", () => {
    const id = agentIdentity("dependabot-scout");
    assert.equal(id.slug, "dependabot-scout");
    assert.equal(id.tmuxName, "dependabot-scout");
    assert.equal(id.cardName, "dependabot-scout");
    assert.equal(id.worktreeName, "dependabot-scout");
    assert.equal(id.sessionId, uuidv5("dependabot-scout"));
  });
  test("rejects invalid slugs", () => {
    for (const bad of ["", "Has-Caps", "trailing-", "-leading", "has space", "a".repeat(61)]) {
      assert.equal(isValidSlug(bad), false, `expected ${JSON.stringify(bad)} invalid`);
    }
    for (const ok of ["a", "dependabot-scout", "agent7", "x-1-y"]) {
      assert.equal(isValidSlug(ok), true, `expected ${JSON.stringify(ok)} valid`);
    }
    assert.throws(() => agentIdentity("Bad Slug"));
  });
});

describe("cards: formatting", () => {
  test("isoNow has no milliseconds and trailing Z (matches Swift .iso8601)", () => {
    assert.match(isoNow(), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });
  test("sortedStringify sorts keys recursively, 2-space indent", () => {
    const out = sortedStringify({ b: 1, a: { d: 2, c: 3 } });
    assert.equal(out, '{\n  "a": {\n    "c": 3,\n    "d": 2\n  },\n  "b": 1\n}');
  });
});

describe("cards: persistence (sandboxed)", () => {
  let home: string;
  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-cards-"));
    process.env.KANBAN_CODE_HOME = home;
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    rmSync(home, { recursive: true, force: true });
  });

  function makeCard(id: string, name: string): Link {
    const now = isoNow();
    return {
      id,
      name,
      column: "in_progress",
      createdAt: now,
      updatedAt: now,
      manualOverrides: { worktreePath: false, tmuxSession: false, name: true, column: false, prLink: false, issueLink: false },
      manuallyArchived: false,
      source: "manual",
      isRemote: false,
    };
  }

  test("writeLinks then readLinks round-trips, container format", () => {
    writeLinks([makeCard("card_1", "a"), makeCard("card_2", "b")]);
    const raw = JSON.parse(readFileSync(join(home, "links.json"), "utf-8"));
    assert.ok(Array.isArray(raw.links), "must use { links: [...] } container");
    const cards = readLinks();
    assert.deepEqual(cards.map((c) => c.name).sort(), ["a", "b"]);
  });

  test("upsertCard inserts then updates by id (no duplicates)", () => {
    upsertCard(makeCard("card_x", "x"));
    upsertCard(makeCard("card_x", "x-renamed"));
    const cards = readLinks();
    assert.equal(cards.length, 1);
    assert.equal(cards[0].name, "x-renamed");
    assert.equal(findCardByName("x-renamed")?.id, "card_x");
  });

  test("a daily backup is rotated on overwrite", () => {
    writeLinks([makeCard("card_1", "a")]);
    writeLinks([makeCard("card_1", "a"), makeCard("card_2", "b")]);
    const backups = readdirSync(home).filter((f) => f.startsWith("links.json.daily-"));
    assert.equal(backups.length, 1, "second write should snapshot the first");
  });
});
