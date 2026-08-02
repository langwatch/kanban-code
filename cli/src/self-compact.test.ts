import { describe, test } from "node:test";
import { strict as assert } from "node:assert";
import {
  DEFAULT_SELF_COMPACT_RULES,
  cardSelfCompactRules,
  effectiveSelfCompactRules,
  normalizeSelfCompactAction,
  parseContextThreshold,
} from "./self-compact.js";
import { parseDeliveryMode } from "./delivery.js";

describe("card self-compact policy", () => {
  test("parses k-suffixed and integer token thresholds exactly", () => {
    assert.equal(parseContextThreshold("250k"), 250_000);
    assert.equal(parseContextThreshold("250K"), 250_000);
    assert.equal(parseContextThreshold("250000"), 250_000);
  });

  test("rejects zero, negative, malformed, and overflowing thresholds", () => {
    for (const value of ["0", "-250k", "250m", "250.5k", "9007199254740991k"]) {
      assert.throws(() => parseContextThreshold(value), /Invalid context threshold/);
    }
  });

  test("creates one nudge and a forced compact 200k later", () => {
    const rules = cardSelfCompactRules(250_000);
    assert.deepEqual(rules.map((rule) => [rule.thresholdTokens, rule.action]), [
      [250_000, "queuePrompt"],
      [350_000, "steer"],
      [450_000, "interrupt"],
    ]);
    assert.match(rules[0].message, /250k context limit/);
    assert.match(rules[0].message, /passing an argument for the post-compact message on how to continue/);
    assert.match(rules[1].message, /350k context limit/);
    assert.equal(rules[2].message, "/compact");
  });

  test("defaults steer before the last threshold interrupts", () => {
    const actions = DEFAULT_SELF_COMPACT_RULES.map((rule) => rule.action);

    assert.equal(actions.at(-1), "interrupt");
    assert.equal(actions.at(-2), "steer");
    assert.ok(actions.slice(0, -2).every((action) => action === "queuePrompt"));
  });

  test("settings saved before the split read compactNow as steer", () => {
    assert.equal(normalizeSelfCompactAction("compactNow"), "steer");
    assert.equal(normalizeSelfCompactAction("interrupt"), "interrupt");
    assert.equal(normalizeSelfCompactAction("steer"), "steer");
    assert.equal(normalizeSelfCompactAction(undefined), "queuePrompt");
  });

  test("delivery modes accept both spellings of queue", () => {
    assert.equal(parseDeliveryMode(undefined), "steer");
    assert.equal(parseDeliveryMode("queue"), "queue");
    assert.equal(parseDeliveryMode("enqueue"), "queue");
    assert.equal(parseDeliveryMode("INTERRUPT"), "interrupt");
    assert.throws(() => parseDeliveryMode("yell"), /Invalid --mode/);
  });

  test("a card threshold replaces global rules even when the global guard is disabled", () => {
    assert.deepEqual(
      effectiveSelfCompactRules(300_000, false, DEFAULT_SELF_COMPACT_RULES),
      cardSelfCompactRules(300_000)
    );
  });

  test("a card without an override follows the global guard unchanged", () => {
    assert.deepEqual(effectiveSelfCompactRules(undefined, true, DEFAULT_SELF_COMPACT_RULES), DEFAULT_SELF_COMPACT_RULES);
    assert.deepEqual(effectiveSelfCompactRules(undefined, false, DEFAULT_SELF_COMPACT_RULES), []);
  });
});
