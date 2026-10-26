import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { runKv, type VaultIO } from "./vault.js";
import { EXIT_MOVED, movedAmong, movedMessage, readMoved } from "./vault-moved.js";

async function fakeMaster(handler: (path: string, body: any) => unknown) {
  const calls: { path: string; body: any }[] = [];
  const server = createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const body = data ? JSON.parse(data) : undefined;
      calls.push({ path: req.url!, body });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(handler(req.url!, body)));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, calls, close: () => server.close() };
}

function kvIo(url: string, moved: Record<string, string>, notes: string[], out: string[] = []): VaultIO & { hits: string } {
  const hits = join(mkdtempSync(join(tmpdir(), "kv-moved-")), "hits.jsonl");
  return {
    env: { KANBAN_VAULT_URL: url, KANBAN_CARD_ID: "card_x" },
    fetch,
    stderr: (t) => notes.push(t),
    stdout: (t) => out.push(t),
    sleep: async () => {},
    moved: { names: moved, hitsLog: hits },
    hits,
  };
}

test("reads moved.json and ignores anything that is not a name to connection map", () => {
  const dir = mkdtempSync(join(tmpdir(), "kv-moved-"));
  const file = join(dir, "moved.json");
  writeFileSync(file, JSON.stringify({ SLACK_USER_TOKEN: "slack-user-token", BAD: 3 }));
  assert.deepEqual(readMoved(file), { SLACK_USER_TOKEN: "slack-user-token" });
  writeFileSync(file, "[1]");
  assert.deepEqual(readMoved(file), {});
  assert.deepEqual(readMoved(join(dir, "missing.json")), {});
});

test("a moved name is matched by what was asked or by the secret it resolved to", () => {
  const moved = { GRANOLA_API_KEY: "granola-api-key" };
  assert.deepEqual(movedAmong(["GRANOLA_API_KEY", "OTHER"], moved), [{ asked: "GRANOLA_API_KEY", connection: "granola-api-key" }]);
  assert.deepEqual(movedAmong(["GRANOLA"], moved, { GRANOLA: "GRANOLA_API_KEY" }), [{ asked: "GRANOLA", connection: "granola-api-key" }]);
  assert.match(movedMessage([{ asked: "A", connection: "a" }]), /kv: moved to laze vault: A \(connection a\)\nkv: Use the Laze vault instead: laze vault run a/);
});

test("a deleted name says where it lives now and points at no Laze connection", () => {
  const message = movedMessage([{ asked: "laze/prod/AUTH_SECRET", connection: "deleted:prod reads it from Scaleway Secret Manager" }]);
  assert.equal(message, "kv: deleted from the Kanban vault: laze/prod/AUTH_SECRET (prod reads it from Scaleway Secret Manager)");
  const mixed = movedMessage([
    { asked: "A", connection: "a" },
    { asked: "B", connection: "deleted:gone" },
  ]);
  assert.match(mixed, /kv: deleted from the Kanban vault: B \(gone\)\nkv: moved to laze vault: A \(connection a\)\nkv: Use the Laze vault instead: laze vault run a /);
});

test("kv run and kv get refuse a moved name before asking the master, and log the hit", async () => {
  const m = await fakeMaster(() => ({ status: "granted", message: "", values: { A: "1" } }));
  const notes: string[] = [];
  const io = kvIo(m.url, { SLACK_USER_TOKEN: "slack-user-token" }, notes);
  await assert.rejects(runKv(["run", "A", "SLACK_USER_TOKEN", "--", "true"], io), (e: any) => {
    assert.equal(e.code, EXIT_MOVED);
    assert.match(e.message, /moved to laze vault: SLACK_USER_TOKEN \(connection slack-user-token\)/);
    return true;
  });
  await assert.rejects(runKv(["get", "SLACK_USER_TOKEN"], io), (e: any) => e.code === EXIT_MOVED);
  m.close();
  assert.equal(m.calls.length, 0);
  const hits = readFileSync(io.hits, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(hits.map((h) => [h.name, h.mode, h.cardId]), [
    ["SLACK_USER_TOKEN", "run", "card_x"],
    ["SLACK_USER_TOKEN", "get", "card_x"],
  ]);
});

test("kv run of names that did not move is unchanged", async () => {
  const m = await fakeMaster(() => ({ status: "granted", message: "", values: { A: "1" } }));
  const code = await runKv(["run", "A", "--", "sh", "-c", 'test "$A" = 1'], kvIo(m.url, { B: "b" }, []));
  m.close();
  assert.equal(code, 0);
  assert.deepEqual(m.calls.map((c) => c.path), ["/v1/vault/release"]);
});

test("kv env refuses a manifest that resolves to a moved secret", async () => {
  const root = mkdtempSync(join(tmpdir(), "kv-moved-env-"));
  writeFileSync(join(root, ".env.vault"), "OPENAI_API_KEY\nPORT=1\n");
  const m = await fakeMaster((path) =>
    path === "/v1/vault/resolve"
      ? { status: "granted", message: "resolved", resolved: { OPENAI_API_KEY: "OPENAI_API_KEY", OWN: "shop/dev/OWN" } }
      : { status: "granted", message: "", env: {} }
  );
  const io = kvIo(m.url, { OPENAI_API_KEY: "openai-api-key" }, []);
  await assert.rejects(runKv(["env", join(root, ".env.vault"), "--", "true"], io), (e: any) => e.code === EXIT_MOVED);
  m.close();
  assert.deepEqual(m.calls.map((c) => c.path), ["/v1/vault/resolve"]);
});

test("the Bash hook leaves moved secrets out, names them only when the command uses them, and loads the rest", async () => {
  const root = mkdtempSync(join(tmpdir(), "kv-moved-hook-"));
  writeFileSync(join(root, ".env.vault"), "OPENAI_API_KEY\nDB={{vault:shop/dev/DB}}\n");
  const m = await fakeMaster((path) =>
    path === "/v1/vault/resolve"
      ? {
          status: "granted",
          message: "resolved",
          resolved: { OPENAI_API_KEY: "OPENAI_API_KEY", "shop/dev/DB": "shop/dev/DB", OWN: "shop/dev/OWN" },
        }
      : { status: "granted", message: "", values: { "shop/dev/DB": "db" }, env: { OWN: "o" } }
  );
  const quiet: string[] = [];
  const out: string[] = [];
  const b64 = (c: string) => Buffer.from(c).toString("base64");
  const io = kvIo(m.url, { OPENAI_API_KEY: "openai-api-key" }, quiet, out);
  assert.equal(await runKv(["env", join(root, ".env.vault"), "--export", "--command-b64", b64("ls")], io), 0);
  assert.equal(quiet.join(""), "");
  assert.match(out.join(""), /export DB=db/);
  assert.match(out.join(""), /export OWN=o/);
  assert.doesNotMatch(out.join(""), /OPENAI/);
  const release = m.calls.find((c) => c.path === "/v1/vault/release")!;
  assert.deepEqual(release.body.names, ["shop/dev/DB"]);
  assert.deepEqual(release.body.keys, ["OWN"]);
  assert.equal(release.body.group, false);

  const loud: string[] = [];
  const io2 = kvIo(m.url, { OPENAI_API_KEY: "openai-api-key" }, loud, []);
  assert.equal(await runKv(["env", join(root, ".env.vault"), "--export", "--command-b64", b64("echo $OPENAI_API_KEY")], io2), 0);
  m.close();
  assert.match(loud.join(""), /moved to laze vault: OPENAI_API_KEY/);
  assert.equal(JSON.parse(readFileSync(io2.hits, "utf8")).mode, "hook");
});
