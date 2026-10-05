import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  EXIT_DENIED,
  VaultClient,
  checkedReason,
  describeInvoker,
  invokingCommand,
  readNamePlan,
  envFromVault,
  environmentOf,
  findEnvVault,
  hookRewrite,
  manifestName,
  manifestRequest,
  parseSecretName,
  secretDisplay,
  execProviderAnswer,
  LOG_COMMAND_LIMIT,
  leasePolicyFlags,
  leaseText,
  logCommand,
  parseEnvVault,
  parseLease,
  reasonProblem,
  runKv,
  shellQuote,
  type VaultIO,
} from "./vault.js";
import { envVaultFor, environmentOfEnvFile, isSecret, planAws, planSecrets, renderPlan, tierFor } from "./vault-import.js";

test("parses .env.vault references and plain values", () => {
  const entries = parseEnvVault(`# comment\nOPENAI_API_KEY={{vault:OPENAI_API_KEY}}\nexport DB={{ vault:DB_URL }}\nPORT=3000\nNAME="a b"\n`);
  assert.deepEqual(entries, [
    { key: "OPENAI_API_KEY", secret: "OPENAI_API_KEY" },
    { key: "DB", secret: "DB_URL" },
    { key: "PORT", value: "3000" },
    { key: "NAME", value: "a b" },
  ]);
  assert.deepEqual(envFromVault(entries, { OPENAI_API_KEY: "v1" }), { OPENAI_API_KEY: "v1", PORT: "3000", NAME: "a b" });
});

test("shell quoting survives quotes", () => {
  assert.equal(shellQuote("plain-word"), "plain-word");
  assert.equal(shellQuote("it's"), `'it'\\''s'`);
  assert.equal(shellQuote("a b"), "'a b'");
});

test("the hook wraps Bash commands only in projects with .env.vault", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-hook-"));
  mkdirSync(join(root, "repo/.git"), { recursive: true });
  mkdirSync(join(root, "repo/sub"), { recursive: true });
  mkdirSync(join(root, "other/.git"), { recursive: true });
  writeFileSync(join(root, "repo/.env.vault"), "A={{vault:A}}\n");
  assert.equal(findEnvVault(join(root, "repo/sub"), root), join(root, "repo/.env.vault"));
  assert.equal(findEnvVault(join(root, "other"), root), undefined);

  // A linked worktree without its own .env.vault uses the main checkout's.
  mkdirSync(join(root, "repo/.git/worktrees/wt"), { recursive: true });
  mkdirSync(join(root, "wt/sub"), { recursive: true });
  writeFileSync(join(root, "wt/.git"), `gitdir: ${join(root, "repo/.git/worktrees/wt")}\n`);
  assert.equal(findEnvVault(join(root, "wt/sub"), root), join(root, "repo/.env.vault"));
  writeFileSync(join(root, "wt/.env.vault"), "A={{vault:A}}\n");
  assert.equal(findEnvVault(join(root, "wt/sub"), root), join(root, "wt/.env.vault"));

  const out = hookRewrite({ tool_name: "Bash", tool_input: { command: "cd x && pnpm test" }, cwd: join(root, "repo/sub") }, "/bin/kv") as {
    hookSpecificOutput: { updatedInput: { command: string } };
  };
  const cmd = out.hookSpecificOutput.updatedInput.command;
  assert.match(cmd, /env .*\.env\.vault --export --command-b64 /);
  assert.ok(cmd.endsWith("\ncd x && pnpm test"));
  assert.equal(hookRewrite({ tool_name: "Bash", tool_input: { command: cmd }, cwd: join(root, "repo") }, "/bin/kv"), undefined);
  assert.equal(hookRewrite({ tool_name: "Read", tool_input: {}, cwd: join(root, "repo") }, "/bin/kv"), undefined);
  assert.equal(hookRewrite({ tool_name: "Bash", tool_input: { command: "ls" }, cwd: join(root, "other") }, "/bin/kv"), undefined);
});

test("the hook answers Codex with permissionDecision allow and Claude Code without it", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-hook-"));
  mkdirSync(join(root, "repo/.git"), { recursive: true });
  writeFileSync(join(root, "repo/.env.vault"), "A={{vault:A}}\n");
  const input = { tool_name: "Bash", tool_input: { command: "pnpm test" }, cwd: join(root, "repo") };
  type Out = { hookSpecificOutput: { permissionDecision?: string; updatedInput: { command: string } } };
  const claude = hookRewrite(input, "/bin/kv") as Out;
  const codex = hookRewrite(input, "/bin/kv", "codex") as Out;
  assert.equal(claude.hookSpecificOutput.permissionDecision, undefined);
  assert.equal(codex.hookSpecificOutput.permissionDecision, "allow");
  assert.equal(codex.hookSpecificOutput.updatedInput.command, claude.hookSpecificOutput.updatedInput.command);
});

async function fakeMaster(handler: (method: string, path: string, body: any) => { status: number; body: unknown }) {
  const calls: { method: string; path: string; body: any; headers: Record<string, string | string[] | undefined> }[] = [];
  const server = createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const body = data ? JSON.parse(data) : undefined;
      calls.push({ method: req.method!, path: req.url!, body, headers: req.headers });
      const r = handler(req.method!, req.url!, body);
      res.writeHead(r.status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(r.body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { url, calls, close: () => server.close() };
}

function io(url: string, notes: string[]): VaultIO {
  return { env: { KANBAN_VAULT_URL: url, KANBAN_CARD_ID: "card_x" }, fetch, stderr: (t) => notes.push(t), sleep: async () => {} };
}

test("a pending release waits for the approval and says so", async () => {
  let polls = 0;
  const m = await fakeMaster((method, path) => {
    if (path === "/v1/vault/release") return { status: 202, body: { status: "pending", id: "vault_1", message: "Waiting for Rogerio's approval on his phone or Mac (card X)" } };
    polls++;
    return polls < 3
      ? { status: 202, body: { status: "pending", id: "vault_1", message: "still waiting" } }
      : { status: 200, body: { status: "granted", message: "released", values: { A: "1" } } };
  });
  const notes: string[] = [];
  const r = await new VaultClient(m.url, io(m.url, notes)).decide("release", { mode: "run", names: ["A"] });
  m.close();
  assert.equal(r.status, "granted");
  assert.deepEqual(r.values, { A: "1" });
  assert.match(notes.join(""), /Waiting for Rogerio's approval/);
});

test("a denial exits with the denied code and a hint", async () => {
  const m = await fakeMaster(() => ({ status: 403, body: { status: "denied", message: "Rogerio denied it." } }));
  await assert.rejects(runKv(["run", "A", "--", "true"], io(m.url, [])), (e: any) => {
    assert.equal(e.code, EXIT_DENIED);
    assert.match(e.message, /kv request NAME --reason/);
    return true;
  });
  m.close();
});

test("kv run passes the command line for Jev", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", values: { A: "v" } } }));
  const reason = "Check that the test script sees the key it needs";
  const code = await runKv(["run", "A", "--reason", reason, "--", "sh", "-c", 'test "$A" = v'], io(m.url, []));
  m.close();
  assert.equal(code, 0);
  assert.equal(m.calls[0].body.command, `sh -c 'test "$A" = v'`);
  assert.equal(m.calls[0].body.reason, reason);
});

test("reasons must be one plain sentence a human reads on a phone", () => {
  assert.equal(reasonProblem(undefined), "missing");
  assert.equal(reasonProblem("change aws:lw-dev: rules"), "tooShort");
  assert.equal(reasonProblem("kubectl apply -f deploy.yaml"), "looksLikeCommand");
  assert.equal(reasonProblem("make build the app"), "looksLikeCommand");
  assert.equal(reasonProblem("Make the key ask on every use"), undefined);
  assert.equal(reasonProblem("run the deploy with --force please"), "looksLikeCommand");
  assert.equal(reasonProblem("load env && run the migration now"), "looksLikeCommand");
  assert.equal(reasonProblem("first line\nsecond line of it"), "tooLong");
  assert.equal(reasonProblem("Deploy the langwatch staging app to check the fix for the login bug"), undefined);
  assert.equal(checkedReason(undefined, {}, false), undefined);
  assert.equal(checkedReason(undefined, { KV_REASON: "Read the dev cluster nodes after the autoscaler change" }, true),
    "Read the dev cluster nodes after the autoscaler change");
  assert.throws(() => checkedReason(undefined, {}, true), (e: any) => e.code === 2 && /one short plain sentence/.test(e.message));
});

test("a terse or command-like reason is refused before asking the master", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", values: { A: "v" } } }));
  for (const argv of [
    ["request", "A", "--reason", "change aws:lw-dev: rules"],
    ["request", "A"],
    ["run", "A", "--reason", "aws s3 ls", "--", "true"],
    ["rules", "A", "deploys only", "--reason", "rules"],
  ]) {
    await assert.rejects(runKv(argv, io(m.url, [])), (e: any) => {
      assert.equal(e.code, 2, argv.join(" "));
      assert.match(e.message, /Deploy the langwatch staging app/);
      return true;
    });
  }
  assert.equal(m.calls.length, 0);
  const reason = "Let the release script post the notes on its own";
  await runKv(["label", "A", "Release bot token", "--reason", reason], io(m.url, []));
  m.close();
  assert.deepEqual(m.calls[0].body, { label: "Release bot token", reason });
});

test("import finds secrets, skips config and placeholders", () => {
  assert.ok(isSecret("OPENAI_API_KEY", "sk-proj-abcdefghijklmnopqrstuvwxyz0123"));
  assert.ok(isSecret("DATABASE_URL", "postgres://user:pa55word@db.example.com:5432/app"));
  assert.ok(!isSecret("DATABASE_URL", "postgres://localhost:5432/app"));
  assert.ok(!isSecret("PORT", "3000"));
  assert.ok(!isSecret("OPENAI_API_KEY", "your-key-here"));
  assert.ok(!isSecret("API_KEY", "changeme"));
  assert.ok(!isSecret("NODE_ENV", "development"));
  assert.equal(tierFor("OPENAI_API_KEY", "sk-proj-x").tier, "open");
  assert.equal(tierFor("CLOUDFLARE_API_TOKEN", "abc").tier, "judged");
  assert.equal(tierFor("STRIPE_SECRET_KEY", "sk_live_abc").tier, "ask");
  assert.equal(tierFor("KANBAN_TOKEN", "kc_abc").tier, "never");
});

test("import dedupes by value and never writes values into the plan", () => {
  const plans = planSecrets(
    [
      { key: "OPENAI_API_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/a/.env" },
      { key: "OPENAI_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/b/.env" },
      { key: "OPENAI_API_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/c/.env" },
      { key: "OPENAI_API_KEY", value: "sk-proj-value-two-bbbbbbbbbbbb", file: "/h/Projects/d/.env" },
    ],
    "/h"
  );
  assert.deepEqual(plans.map((p) => p.name), ["d/dev/OPENAI_API_KEY", "OPENAI_API_KEY"]);
  assert.equal(plans.find((p) => p.name === "OPENAI_API_KEY")?.sources.length, 3);
  const md = renderPlan(plans, ["/h/Projects/a/.env"], "/h");
  assert.ok(!md.includes("sk-proj-value"));
  assert.match(md, /`OPENAI_API_KEY`: ~\/Projects\/a\/.env OPENAI_API_KEY/);
});

test("import plans AWS profiles with read leases for prod", () => {
  const plans = planAws(
    `[root]\naws_access_key_id = AKIAEXAMPLE\naws_secret_access_key = s3cr3t\n\n[lw-prod]\nsource_profile = root\nrole_arn = arn:aws:iam::1:role/R\n\n[lw-dev]\nsource_profile = root\nrole_arn = arn:aws:iam::2:role/R\n`,
    "/h"
  );
  const byName = Object.fromEntries(plans.map((p) => [p.name, p]));
  assert.equal(byName["AWS_KEY_ROOT"].tier, "never");
  assert.equal(byName["aws:lw-dev"].tier, "judged");
  assert.equal(byName["aws:lw-prod:read"].tier, "ask");
  assert.deepEqual(byName["aws:lw-prod:read"].aws?.policyArns, ["arn:aws:iam::aws:policy/ReadOnlyAccess"]);
  assert.equal(byName["aws:lw-prod"].everyUseAsks, true);
});

test(".env.vault keeps names and plain config only", () => {
  const out = envVaultFor("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz\nPORT=3000\nWEIRD=Zx9kLmQ2vB7nR4tY8uW1eA3sD6fG\n", new Map([["OPENAI_API_KEY", "OPENAI_API_KEY"]]));
  assert.match(out, /^OPENAI_API_KEY$/m);
  assert.match(out, /PORT=3000/);
  assert.ok(!out.includes("sk-proj"));
  assert.ok(!out.includes("Zx9kLmQ2"));
});

test("the exec provider answers OpenClaw's protocol without waiting on a human", async () => {
  const m = await fakeMaster((_method, _path, body) => {
    const name = body.names[0];
    if (name === "OPEN") return { status: 200, body: { status: "granted", message: "released", values: { OPEN: "v1" } } };
    if (name === "ASK") return { status: 202, body: { status: "pending", id: "vault_1", message: "Waiting" } };
    return { status: 403, body: { status: "denied", message: `no secret named ${name} in the vault` } };
  });
  const client = new VaultClient(m.url, io(m.url, []));
  const answer = await execProviderAnswer(client, { protocolVersion: 1, provider: "kv", ids: ["OPEN", "ASK", "GONE"] }, { cwd: "/" });
  m.close();
  assert.deepEqual(answer, {
    protocolVersion: 1,
    values: { OPEN: "v1" },
    errors: { ASK: { code: "NEEDS_APPROVAL" }, GONE: { code: "NOT_FOUND" } },
  });
  assert.equal(m.calls.length, 3);
  assert.equal(m.calls[0].body.mode, "get");
});

test("--lease takes a length from one minute to two days", () => {
  assert.equal(parseLease("1h"), 3600);
  assert.equal(parseLease("30m"), 1800);
  assert.equal(parseLease("2d"), 172800);
  assert.equal(parseLease("90s"), 90);
  assert.equal(parseLease("1h30m"), 5400);
  assert.equal(parseLease(" 8H "), 28800);
  assert.equal(parseLease("1m"), 60);
  for (const bad of ["", "1", "h", "1 hour", "1.5h", "-1h", "1w", "abc", "1h-30m", "0x10m"]) {
    assert.throws(() => parseLease(bad), /--lease takes a length/, bad);
  }
  assert.throws(() => parseLease("59s"), /at least 1 minute/);
  assert.throws(() => parseLease("0m"), /at least 1 minute/);
  assert.throws(() => parseLease("3d"), /at most 2 days/);
  assert.throws(() => parseLease("49h"), /at most 2 days/);
  assert.throws(() => parseLease("99999999999999999999d"), /at most 2 days|at least 1 minute/);
});

test("a lease length prints in its largest whole unit", () => {
  assert.equal(leaseText(172800), "2d");
  assert.equal(leaseText(3600), "1h");
  assert.equal(leaseText(28800), "8h");
  assert.equal(leaseText(5400), "90m");
  assert.equal(leaseText(900), "15m");
  assert.equal(leaseText(90), "90s");
});

test("--lease sets the lease length and contradicts --every-use-asks", () => {
  const a = ["METABASE_API_KEY", "ask", "--lease", "1h"];
  assert.deepEqual(leasePolicyFlags(a), { leaseSeconds: 3600, everyUseAsks: false });
  assert.deepEqual(a, ["METABASE_API_KEY", "ask"]);
  assert.deepEqual(leasePolicyFlags(["X", "--leases", "--lease", "30m"]), { leaseSeconds: 1800, everyUseAsks: false });
  assert.throws(() => leasePolicyFlags(["X", "--lease", "1h", "--every-use-asks"]), /contradict/);
  assert.throws(() => leasePolicyFlags(["X", "--lease"]), /needs a length/);
  assert.throws(() => leasePolicyFlags(["X", "--lease", "--reason"]), /needs a length/);
  assert.throws(() => leasePolicyFlags(["X", "--lease", "5d"]), /at most 2 days/);
});

test("kv tier --lease sends the length; kv ls and kv leases show it", async () => {
  const listed = [
    { name: "METABASE_API_KEY", tier: "ask", rules: "", leasePolicy: { leaseSeconds: 3600, everyUseAsks: false }, tags: [], sources: [], hasValue: true },
    { name: "STRIPE", tier: "ask", rules: "", leasePolicy: { leaseSeconds: 172800, everyUseAsks: true }, tags: [], sources: [], hasValue: true },
    { name: "OPENAI", tier: "judged", rules: "", leasePolicy: { leaseSeconds: 172800, everyUseAsks: false }, tags: [], sources: [], hasValue: true },
    { name: "PROD_DB", tier: "ask", rules: "", leasePolicy: { leaseSeconds: 172800, everyUseAsks: false }, tags: [], sources: [], hasValue: true },
    { name: "SENTRY", tier: "judged", rules: "", leasePolicy: { leaseSeconds: 900, everyUseAsks: false }, tags: [], sources: [], hasValue: true },
  ];
  const leases = [{ cardId: "card_1", secret: "METABASE_API_KEY", grantedAt: "2026-10-05T10:00:00.000Z", expiresAt: "2026-10-05T11:00:00.000Z" }];
  const m = await fakeMaster((method, url) => {
    if (method === "GET" && url.startsWith("/v1/vault/secrets")) return { status: 200, body: listed };
    if (method === "GET" && url.startsWith("/v1/vault/leases")) return { status: 200, body: leases };
    return { status: 200, body: { status: "granted", message: "changed METABASE_API_KEY" } };
  });
  await runKv(["tier", "METABASE_API_KEY", "ask", "--lease", "1h", "--reason", "Limit how long a card keeps the Metabase key"], io(m.url, []));
  assert.equal(m.calls[0].method, "PATCH");
  assert.deepEqual(m.calls[0].body.leasePolicy, { leaseSeconds: 3600, everyUseAsks: false });
  await runKv(["tiers", "ask", "A", "B", "--lease", "30m", "--reason", "Limit how long a card keeps these two keys"], io(m.url, []));
  assert.deepEqual(m.calls[1].body.edit.leasePolicy, { leaseSeconds: 1800, everyUseAsks: false });
  await assert.rejects(runKv(["tier", "METABASE_API_KEY", "ask", "--lease", "3d"], io(m.url, [])), /at most 2 days/);
  assert.equal(m.calls.length, 2);

  const out: string[] = [];
  const printing = { ...io(m.url, []), stdout: (t: string) => out.push(t) };
  await runKv(["ls"], printing);
  const lines = out.join("").split("\n");
  assert.match(lines[0], /^METABASE_API_KEY\s+ask\s+lease 1h/);
  assert.match(lines[1], /^STRIPE\s+ask\s+every use asks/);
  assert.match(lines[2], /^OPENAI\s+judged$/);
  assert.match(lines[3], /^PROD_DB\s+ask\s+lease 2d/);
  assert.match(lines[4], /^SENTRY\s+judged lease 15m/);
  out.length = 0;
  await runKv(["ls", "--json"], printing);
  assert.equal(JSON.parse(out.join(""))[0].leasePolicy.leaseSeconds, 3600);
  out.length = 0;
  await runKv(["leases"], printing);
  assert.match(out.join(""), /METABASE_API_KEY.*card card_1  until 2026-10-05T11:00 \(1h lease\)/);
  await m.close();
});

test("kv log shows the command of each line on one line, cut when long", async () => {
  const entries = [
    { at: "2026-10-05T10:00:01.200Z", machine: "box", cardId: "card_1", secret: "OPENAI", outcome: "allowed", decider: "jev", action: "run", command: "python report.py\n  --week 40", detail: "Jev allowed (90%)" },
    { at: "2026-10-05T10:00:01.000Z", machine: "box", cardId: "card_1", secret: "METABASE_API_KEY", outcome: "allowed", decider: "lease", action: "run", command: "python report.py\n  --week 40", detail: "the card holds a lease" },
    { at: "2026-10-05T10:00:00.000Z", machine: "box", cardId: "card_1", secret: "METABASE_API_KEY", outcome: "allowed", decider: "human", action: "lease", detail: "by mac, card lease of 1 hour" },
  ];
  const m = await fakeMaster(() => ({ status: 200, body: entries }));
  const out: string[] = [];
  await runKv(["log", "--secret", "METABASE_API_KEY"], { ...io(m.url, []), stdout: (t: string) => out.push(t) });
  const lines = out.join("").split("\n");
  // The two secrets of one command share its line.
  assert.match(lines[0], /allowed jev\s+run\s+.*OPENAI/);
  assert.match(lines[1], /allowed lease\s+run\s+.*METABASE_API_KEY.*\(the card holds a lease\)/);
  assert.equal(lines[2], "    $ python report.py --week 40");
  assert.match(lines[3], /by mac, card lease of 1 hour/);
  assert.equal(lines[4], "");
  assert.equal(logCommand("x".repeat(LOG_COMMAND_LIMIT + 50)), "x".repeat(LOG_COMMAND_LIMIT) + "...");
  await m.close();
});

test("--every-use-asks and --leases set the lease policy, together they are refused", () => {
  const a = ["STRIPE", "ask", "--every-use-asks"];
  assert.deepEqual(leasePolicyFlags(a), { leaseSeconds: 172800, everyUseAsks: true });
  assert.deepEqual(a, ["STRIPE", "ask"]);
  assert.deepEqual(leasePolicyFlags(["X", "--leases"]), { leaseSeconds: 172800, everyUseAsks: false });
  assert.equal(leasePolicyFlags(["X", "ask"]), undefined);
  assert.throws(() => leasePolicyFlags(["X", "--leases", "--every-use-asks"]), /contradict/);
});

test("kv tier sends the lease policy with the tier", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "changed STRIPE: tier, every use asks" } }));
  await runKv(["tier", "STRIPE_API_KEY", "ask", "--every-use-asks", "--reason", "Stripe live key must ask on every use"], io(m.url, []));
  m.close();
  assert.equal(m.calls[0].method, "PATCH");
  assert.deepEqual(m.calls[0].body.leasePolicy, { leaseSeconds: 172800, everyUseAsks: true });
  assert.equal(m.calls[0].body.tier, "ask");
});

test("a vault denial says what the vault said, without the reason-writing help", async () => {
  const message = "denied:\n  AWS: Jev denied it against the secret's rules (91%). Its rules: dev work only";
  const m = await fakeMaster(() => ({ status: 403, body: { status: "denied", message } }));
  await assert.rejects(
    runKv(["run", "AWS", "--reason", "Deploy the staging app to check the login fix", "--", "true"], io(m.url, [])),
    (e: any) => {
      assert.match(e.message, /Jev denied it against the secret's rules \(91%\)\. Its rules: dev work only/);
      assert.doesNotMatch(e.message, /Good:|Bad:/);
      return true;
    }
  );
  m.close();
});

test("kv tiers sends one batched change with names and value prefixes", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "changed A, B: tier ask" } }));
  await runKv(
    ["tiers", "ask", "A", "--value-prefix", "sk_live_", "--value-prefix", "rk_live_", "--every-use-asks",
     "--reason", "Live Stripe keys must ask Rogerio on every use"],
    io(m.url, [])
  );
  m.close();
  assert.equal(m.calls.length, 1);
  assert.equal(m.calls[0].method, "PATCH");
  assert.equal(m.calls[0].path, "/v1/vault/secrets");
  assert.deepEqual(m.calls[0].body.names, ["A"]);
  assert.deepEqual(m.calls[0].body.valuePrefixes, ["sk_live_", "rk_live_"]);
  assert.deepEqual(m.calls[0].body.edit.leasePolicy, { leaseSeconds: 172800, everyUseAsks: true });
});

function refused(code = "ECONNREFUSED"): Error {
  return new TypeError("fetch failed", { cause: { code } });
}

function scriptedIO(steps: (() => Response)[], notes: string[], slept: number[]): { io: VaultIO; calls: string[] } {
  const calls: string[] = [];
  const fakeFetch = (async (url: string, init?: RequestInit) => {
    calls.push(`${init?.method} ${url}`);
    const step = steps.shift() ?? (() => { throw refused(); });
    return step();
  }) as unknown as typeof fetch;
  return { io: { env: {}, fetch: fakeFetch, stderr: (t) => notes.push(t), sleep: async (ms) => { slept.push(ms); } }, calls };
}

const json = (status: number, body: unknown) => () => new Response(JSON.stringify(body), { status });

test("a pending approval outlives a master restart: kv waits for the master to come back", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio } = scriptedIO(
    [
      json(202, { status: "pending", id: "vault_1", message: "Waiting for Rogerio" }),
      () => { throw refused(); },
      () => { throw refused(); },
      json(503, { error: "starting" }),
      json(200, { status: "granted", message: "released", values: { A: "1" } }),
    ],
    notes,
    slept
  );
  const r = await new VaultClient("http://127.0.0.1:1", sio).decide("release", { mode: "run", names: ["A"] });
  assert.equal(r.status, "granted");
  assert.equal(notes.filter((n) => /probably restarting; waiting up to 2 min/.test(n)).length, 1);
  assert.ok(notes.some((n) => /the master is back/.test(n)));
  assert.deepEqual(slept, [500, 1000, 2000, 4000]);
});

test("kv gives up after two minutes of a master that does not answer", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio } = scriptedIO([], notes, slept);
  await assert.rejects(new VaultClient("http://127.0.0.1:1", sio).call("GET", "status"), /cannot reach the Kanban Code master/);
  assert.equal(slept.reduce((a, b) => a + b, 0), 120_000);
});

test("a request that may have reached the master is not sent twice", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio, calls } = scriptedIO([() => { throw refused("ECONNRESET"); }], notes, slept);
  await assert.rejects(new VaultClient("http://127.0.0.1:1", sio).call("POST", "release", { names: ["A"] }), /cannot reach/);
  assert.equal(calls.length, 1);
});

test("a POST nothing accepted is retried", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio, calls } = scriptedIO(
    [() => { throw refused(); }, json(200, { status: "granted", message: "ok" })],
    notes,
    slept
  );
  const r = await new VaultClient("http://127.0.0.1:1", sio).call<{ status: string }>("POST", "release", { names: ["A"] });
  assert.equal(r.body.status, "granted");
  assert.equal(calls.length, 2);
});

test("exec-provider does not wait for an unreachable master", async () => {
  const slept: number[] = [];
  const { io: sio } = scriptedIO([], [], slept);
  const client = new VaultClient("http://127.0.0.1:1", sio);
  client.retryForMs = 0;
  const answer = await execProviderAnswer(client, { ids: ["A"] }, { cwd: "/" });
  assert.deepEqual(answer.errors, { A: { code: "UNREACHABLE" } });
  assert.deepEqual(slept, []);
});

test("a secret name splits into project, environment and key", () => {
  assert.deepEqual(parseSecretName("OPENAI_API_KEY"), { key: "OPENAI_API_KEY" });
  assert.deepEqual(parseSecretName("shop/dev/OPENAI_API_KEY"), { key: "OPENAI_API_KEY", environment: "dev", project: "shop" });
  assert.deepEqual(parseSecretName("shop/api/prod/DATABASE_URL"), { key: "DATABASE_URL", environment: "prod", project: "shop/api" });
  assert.deepEqual(parseSecretName("aws:lw-prod:read"), { key: "aws:lw-prod:read" });
  assert.deepEqual(parseSecretName("a/b"), { key: "a/b" });
  assert.equal(secretDisplay("shop/dev/OPENAI_API_KEY"), "OPENAI_API_KEY · shop · dev");
  assert.equal(secretDisplay("OPENAI_API_KEY__SHOP"), "OPENAI_API_KEY__SHOP");
});

test("a manifest has bare keys, named secrets and plain values", () => {
  const entries = parseEnvVault("# shared\nOPENAI_API_KEY\nexport STRIPE_KEY\nDB={{vault:shop/prod/DATABASE_URL}}\nOLD={{vault:TOKEN__SHOP}}\nPORT=3000\n");
  assert.deepEqual(entries, [
    { key: "OPENAI_API_KEY", bare: true },
    { key: "STRIPE_KEY", bare: true },
    { key: "DB", secret: "shop/prod/DATABASE_URL" },
    { key: "OLD", secret: "TOKEN__SHOP" },
    { key: "PORT", value: "3000" },
  ]);
  // The project's values come first, the manifest's own lines win.
  const env = envFromVault(
    entries,
    { "shop/prod/DATABASE_URL": "db", TOKEN__SHOP: "tok" },
    { OPENAI_API_KEY: "own", STRIPE_KEY: "shared", GROUP_ONLY: "g", PORT: "9" }
  );
  assert.deepEqual(env, { OPENAI_API_KEY: "own", STRIPE_KEY: "shared", GROUP_ONLY: "g", PORT: "3000", DB: "db", OLD: "tok" });
});

test("the environment comes from the manifest name", () => {
  assert.equal(environmentOf("/p/shop/.env.vault"), "dev");
  assert.equal(environmentOf("/p/shop/.env.prod.vault"), "prod");
  assert.equal(environmentOf(".env.webinar.vault"), "webinar");
  assert.equal(manifestName("dev"), ".env.vault");
  assert.equal(manifestName("prod"), ".env.prod.vault");
  assert.equal(environmentOfEnvFile("/p/shop/.env"), "dev");
  assert.equal(environmentOfEnvFile("/p/shop/.env.local"), "dev");
  assert.equal(environmentOfEnvFile("/p/shop/.env.prod"), "prod");
});

test("a manifest asks for its names, its bare keys and the project's group", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-manifest-"));
  writeFileSync(join(root, ".env.prod.vault"), "OPENAI_API_KEY\nDB={{vault:OTHER}}\nPORT=3000\n");
  const { body } = manifestRequest(join(root, ".env.prod.vault"), { cwd: "/elsewhere" });
  assert.deepEqual(body, {
    names: ["OTHER"],
    keys: ["OPENAI_API_KEY"],
    defined: ["DB", "PORT"],
    group: true,
    nearest: false,
    dir: root,
    project: undefined,
    environment: "prod",
  });
  // No manifest: the group of the folder's project alone.
  assert.deepEqual(manifestRequest(undefined, { cwd: "/p/shop", environment: "prod", project: "shop" }).body, {
    names: [],
    keys: [],
    defined: [],
    group: true,
    nearest: true,
    dir: "/p/shop",
    project: "shop",
    environment: "prod",
  });
});

test("kv env loads the project's group with the manifest and sends the session token", async () => {
  const root = mkdtempSync(join(tmpdir(), "kv-env-"));
  writeFileSync(join(root, ".env.vault"), "SHARED\nRENAMED={{vault:OLD__NAME}}\nPORT=3000\n");
  const m = await fakeMaster(() => ({
    status: 200,
    body: { status: "granted", message: "released", values: { OLD__NAME: "old" }, env: { SHARED: "s", OWN: "o" } },
  }));
  const kvIo = io(m.url, []);
  kvIo.env.KANBAN_CARD_TOKEN = "kct_abc";
  const check = 'test "$SHARED$OWN$RENAMED$PORT" = soold3000';
  const code = await runKv(["env", join(root, ".env.vault"), "--", "sh", "-c", check], kvIo);
  m.close();
  assert.equal(code, 0);
  const sent = m.calls[0];
  assert.equal(sent.path, "/v1/vault/release");
  assert.equal(sent.headers["x-kanban-card-token"], "kct_abc");
  assert.deepEqual(sent.body.names, ["OLD__NAME"]);
  assert.deepEqual(sent.body.keys, ["SHARED"]);
  assert.deepEqual(sent.body.defined, ["RENAMED", "PORT"]);
  assert.equal(sent.body.group, true);
  assert.equal(sent.body.environment, "dev");
  assert.equal(sent.body.mode, "env");
});

test("kv env --env prod without a file uses the prod manifest of the folder, else the group alone", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", env: { A: "1" } } }));
  const code = await runKv(["env", "--env", "prod", "--project", "shop", "--", "sh", "-c", 'test "$A" = 1'], io(m.url, []));
  m.close();
  assert.equal(code, 0);
  assert.equal(m.calls[0].body.environment, "prod");
  assert.equal(m.calls[0].body.project, "shop");
  assert.equal(m.calls[0].body.group, true);
});

test("kv set stores a project's secret, kv ls filters by project, kv mv renames", async () => {
  const m = await fakeMaster((method, path) => {
    if (path.startsWith("/v1/vault/secrets?project=")) return { status: 200, body: [] };
    if (path.startsWith("/v1/vault/rename")) return { status: 200, body: { status: "granted", message: "renamed 1 of 1 secrets", resolved: { A__SHOP: "rename" } } };
    return { status: 200, body: { status: "granted", message: "added shop/prod/A" } };
  });
  await assert.rejects(runKv(["set", "A", "--env", "prod"], io(m.url, [])), /--env needs --project/);
  assert.equal(await runKv(["ls", "--project", "shop/api"], io(m.url, [])), 0);
  assert.equal(m.calls[0].path, "/v1/vault/secrets?project=shop%2Fapi");
  assert.equal(await runKv(["mv", "A__SHOP", "shop/dev/A", "--reason", "Give the shop key its project name"], io(m.url, [])), 0);
  m.close();
  assert.deepEqual(m.calls[1].body.renames, [{ from: "A__SHOP", to: "shop/dev/A" }]);
});

test("kv same says how a value compares with the stored one and writes no secret", async () => {
  const m = await fakeMaster((_method, _path, body) => ({
    status: 200,
    body: { name: body.name, outcome: body.value === "stored" ? "same" : "different" },
  }));
  const printed: string[] = [];
  const kvIo = (value: string) => ({ ...io(m.url, []), stdin: async () => value, stdout: (t: string) => printed.push(t) });
  assert.equal(await runKv(["same", "METABASE_API_KEY"], kvIo("stored\n")), 0);
  assert.equal(await runKv(["same", "METABASE_API_KEY"], kvIo("rotated")), 0);
  m.close();
  assert.deepEqual(printed, ["same\n", "different\n"]);
  assert.deepEqual(m.calls.map((c) => `${c.method} ${c.path}`), ["POST /v1/vault/compare", "POST /v1/vault/compare"]);
  assert.equal(m.calls[0].body.value, "stored");
});

test("import names a second value after its project and environment", () => {
  const plans = planSecrets(
    [
      { key: "API_KEY", value: "value-one-aaaaaaaaaaaaaaaa", file: "/h/Projects/a/.env" },
      { key: "API_KEY", value: "value-one-aaaaaaaaaaaaaaaa", file: "/h/Projects/b/.env" },
      { key: "API_KEY", value: "value-one-aaaaaaaaaaaaaaaa", file: "/h/Projects/c/.env" },
      { key: "API_KEY", value: "value-two-bbbbbbbbbbbbbbbb", file: "/h/Projects/shop/api/.env.prod" },
      { key: "API_KEY", value: "value-two-bbbbbbbbbbbbbbbb", file: "/h/Projects/shop/api/.env.prod" },
      { key: "API_KEY", value: "value-thr-cccccccccccccccc", file: "/h/Projects/shop/api/.env.prod" },
    ],
    "/h",
    (file) => (file.includes("/shop/api/") ? "shop/api" : "a")
  );
  assert.deepEqual(plans.map((p) => p.name).sort(), ["API_KEY", "shop/api/prod-2/API_KEY", "shop/api/prod/API_KEY"]);
  const manifest = envVaultFor("API_KEY=value-two-bbbbbbbbbbbbbbbb\nOTHER=value-one-aaaaaaaaaaaaaaaa\n",
    new Map([["API_KEY", "shop/api/prod/API_KEY"], ["OTHER", "API_KEY"]]), "shop/api/prod");
  assert.match(manifest, /^API_KEY$/m);
  assert.match(manifest, /^OTHER=\{\{vault:API_KEY\}\}$/m);
});

test("the invoking command is the outermost tool above kv, below the shell", () => {
  const eks = "aws --region eu-central-1 eks get-token --cluster-name dev --output json";
  assert.equal(
    describeInvoker([eks, "kubectl get pods -n langwatch", "/bin/bash -c kubectl get pods -n langwatch", "claude"]),
    `kubectl get pods -n langwatch  (through: ${eks})`
  );
  assert.equal(describeInvoker(["aws s3 ls s3://bucket", "-zsh", "tmux"]), "aws s3 ls s3://bucket");
  assert.equal(describeInvoker(["terraform apply -auto-approve", "/bin/zsh -c terraform apply -auto-approve"]), "terraform apply -auto-approve");
  // Started straight from a shell or a script runner: that is all there is to show.
  assert.equal(describeInvoker(["/bin/bash ./deploy.sh", "claude"]), "/bin/bash ./deploy.sh");
  assert.equal(describeInvoker([]), undefined);
});

test("the invoking command is read from the process ancestry", () => {
  const tree: Record<number, { ppid: number; args: string }> = {
    30: { ppid: 20, args: "aws eks get-token --cluster-name dev" },
    20: { ppid: 10, args: "helm upgrade api ./chart" },
    10: { ppid: 5, args: "/bin/zsh -c helm upgrade api ./chart" },
    5: { ppid: 1, args: "claude" },
  };
  assert.equal(invokingCommand(30, (pid) => tree[pid]), "helm upgrade api ./chart  (through: aws eks get-token --cluster-name dev)");
  assert.equal(invokingCommand(99, (pid) => tree[pid]), undefined);
});

test("kv aws takes its reason from KV_REASON and sends the invoking command", async () => {
  const credentials = { Version: 1, AccessKeyId: "ASIA", SecretAccessKey: "x", SessionToken: "t", Expiration: "2030-01-01T00:00:00Z" };
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", credentials } }));
  const reason = "Check the dev cluster pods after the nlpgo deploy";
  const base = io(m.url, []);
  const code = await runKv(["aws", "lw-dev"], { ...base, env: { ...base.env, KV_REASON: reason } });
  assert.equal(code, 0);
  assert.equal(m.calls[0].path, "/v1/vault/aws");
  assert.equal(m.calls[0].body.reason, reason);
  assert.equal(typeof m.calls[0].body.command, "string");
  assert.ok(!/^kv aws/.test(m.calls[0].body.command));
  // A KV_REASON a human could not read is refused like --reason is.
  await assert.rejects(runKv(["aws", "lw-dev"], { ...base, env: { ...base.env, KV_REASON: "kubectl get pods" } }), (e: any) => e.code === 2);
  m.close();
  assert.equal(m.calls.length, 1);
});

test("kv rm deletes several secrets in one request and needs a reason", async () => {
  const m = await fakeMaster(() => ({
    status: 200,
    body: { status: "granted", message: "deleted 2 of 2 secrets", resolved: { OLD__A: "deleted", OLD__B: "deleted" } },
  }));
  await assert.rejects(runKv(["rm", "OLD__A"], io(m.url, [])), (e: any) => e.code === 2);
  assert.equal(m.calls.length, 0);
  const reason = "Delete two leftover secrets nothing uses any more";
  assert.equal(await runKv(["rm", "OLD__A", "OLD__B", "--reason", reason], io(m.url, [])), 0);
  assert.equal(m.calls[0].path.split("?")[0], "/v1/vault/delete");
  assert.deepEqual(m.calls[0].body, { names: ["OLD__A", "OLD__B"], reason, dryRun: false });

  const dir = mkdtempSync(join(tmpdir(), "kv-rm-"));
  const plan = join(dir, "names.txt");
  writeFileSync(plan, "# leftovers\nOLD__A\n\nOLD__B\n");
  assert.equal(await runKv(["rm", "--plan", plan, "--dry-run", "--reason", reason], io(m.url, [])), 0);
  m.close();
  assert.deepEqual(m.calls[1].body, { names: ["OLD__A", "OLD__B"], reason, dryRun: true });
});

test("a kv rm plan is a JSON array or one name per line", () => {
  assert.deepEqual(readNamePlan('["A", "p/dev/B"]'), ["A", "p/dev/B"]);
  assert.deepEqual(readNamePlan("A\n# note\n  p/dev/B  \n"), ["A", "p/dev/B"]);
  assert.throws(() => readNamePlan('[{"from": "A"}]'), /JSON array of secret names/);
});
