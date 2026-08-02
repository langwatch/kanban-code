import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { slugifyDisplay, truncateSlug, disambiguate, deriveHandle, formatHandle, stripAt } from "./handles.js";

describe("slugifyDisplay", () => {
  test("basic lowercase + underscore", () => {
    assert.equal(slugifyDisplay("Viche Test 1"), "viche_test_1");
  });
  test("strips leading/trailing punctuation", () => {
    assert.equal(slugifyDisplay(" -Hello, World! "), "hello_world");
  });
  test("collapses runs of non-alnum", () => {
    assert.equal(slugifyDisplay("foo---bar..baz"), "foo-bar_baz");
  });
  test("keeps dashes the author chose", () => {
    assert.equal(slugifyDisplay("hi-tester"), "hi-tester");
    assert.equal(slugifyDisplay("Cache Path - v2"), "cache_path-v2");
    assert.equal(slugifyDisplay("Fix the parser"), "fix_the_parser");
  });
  test("empty / only punctuation returns empty", () => {
    assert.equal(slugifyDisplay("!!!"), "");
    assert.equal(slugifyDisplay(""), "");
  });
  test("emoji and unicode are stripped", () => {
    assert.equal(slugifyDisplay("✨ Sparkle Task 🚀"), "sparkle_task");
  });
});

describe("truncateSlug", () => {
  test("no-op when short enough", () => {
    assert.equal(truncateSlug("hello_world", 24), "hello_world");
  });
  test("cuts on underscore boundary when within last 40%", () => {
    // length 29; with maxLen=24, 60% of 24 = 14.4
    assert.equal(truncateSlug("an_extremely_long_descriptive", 24), "an_extremely_long");
  });
  test("no trailing underscore after truncation", () => {
    const out = truncateSlug("abc_defg_hijk_lmnop_qrs_tuvwxyz", 16);
    assert.ok(!out.endsWith("_"));
    assert.ok(out.length <= 16);
  });
});

describe("disambiguate", () => {
  test("returns base when free", () => {
    assert.equal(disambiguate("alice", new Set()), "alice");
  });
  test("appends _2 on first collision", () => {
    assert.equal(disambiguate("alice", new Set(["alice"])), "alice_2");
  });
  test("appends _3 when _2 taken", () => {
    assert.equal(disambiguate("alice", new Set(["alice", "alice_2"])), "alice_3");
  });
  test("shortens base to fit maxLen with suffix", () => {
    const base = "a_very_long_base_handle"; // 23 chars
    const out = disambiguate(base, new Set([base]), 24);
    assert.ok(out.length <= 24);
    assert.ok(out.endsWith("_2"));
  });
});

describe("deriveHandle", () => {
  test("full pipeline: slugify → truncate → disambiguate", () => {
    const h = deriveHandle("Viche Test 1", new Set(["viche_test_1"]), 24);
    assert.equal(h, "viche_test_1_2");
  });
  test("fallback to 'agent' when display is unslugifiable", () => {
    assert.equal(deriveHandle("!!!", new Set()), "agent");
  });
  test("fallback 'agent' disambiguates too", () => {
    assert.equal(deriveHandle("!!!", new Set(["agent"])), "agent_2");
  });
  test("respects maxLen", () => {
    const h = deriveHandle("an extremely long descriptive task title", new Set(), 24);
    assert.ok(h.length <= 24);
  });
});

describe("formatHandle / stripAt", () => {
  test("formatHandle adds @ once", () => {
    assert.equal(formatHandle("alice"), "@alice");
    assert.equal(formatHandle("@alice"), "@alice");
  });
  test("stripAt removes leading @", () => {
    assert.equal(stripAt("@alice"), "alice");
    assert.equal(stripAt("alice"), "alice");
  });
});
