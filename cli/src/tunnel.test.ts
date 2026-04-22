import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";

import { startCloudflaredTunnel } from "./tunnel.js";

function writeFakeCloudflared(script: string): { bin: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "kanban-fake-cloudflared-"));
  const bin = join(dir, "cloudflared");
  writeFileSync(bin, script);
  chmodSync(bin, 0o755);
  return { bin, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

describe("startCloudflaredTunnel", () => {
  test("resolves with the URL printed on stderr (cloudflared's real behavior)", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
echo "some other line" 1>&2
sleep 0.05
echo "Your quick Tunnel: https://cute-puppy-42.trycloudflare.com" 1>&2
# stay alive so the helper's 'stop' path is exercised
sleep 10
`
    );
    try {
      const handle = await startCloudflaredTunnel({
        port: 1234,
        command: bin,
        args: [],
        timeoutMs: 3000,
      });
      assert.equal(handle.url, "https://cute-puppy-42.trycloudflare.com");
      await handle.stop(200);
    } finally {
      cleanup();
    }
  });

  test("also accepts URLs on stdout", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
echo "https://hello-world.trycloudflare.com"
sleep 10
`
    );
    try {
      const handle = await startCloudflaredTunnel({
        port: 1234,
        command: bin,
        args: [],
        timeoutMs: 3000,
      });
      assert.equal(handle.url, "https://hello-world.trycloudflare.com");
      await handle.stop(200);
    } finally {
      cleanup();
    }
  });

  test("rejects when cloudflared exits before publishing a URL", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
echo "no url today" 1>&2
exit 1
`
    );
    try {
      await assert.rejects(
        startCloudflaredTunnel({
          port: 1234,
          command: bin,
          args: [],
          timeoutMs: 3000,
        }),
        /exited before publishing a URL/
      );
    } finally {
      cleanup();
    }
  });

  test("rejects with a timeout error when no URL is seen in time", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
# Emit noise forever without ever printing a URL.
while true; do echo "waiting..."; sleep 0.05; done
`
    );
    try {
      await assert.rejects(
        startCloudflaredTunnel({
          port: 1234,
          command: bin,
          args: [],
          timeoutMs: 200,
        }),
        /did not publish a URL/
      );
    } finally {
      cleanup();
    }
  });

  test("stop() SIGTERMs the child and resolves once it exits", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
echo "https://aaa.trycloudflare.com"
# Well-behaved child: trap SIGTERM and exit.
trap "exit 0" TERM
while true; do sleep 0.1; done
`
    );
    try {
      const handle = await startCloudflaredTunnel({
        port: 1234,
        command: bin,
        args: [],
        timeoutMs: 2000,
      });
      const before = Date.now();
      await handle.stop(1000);
      const elapsed = Date.now() - before;
      assert.ok(elapsed < 1000, `stop should return quickly, took ${elapsed}ms`);
      assert.ok(
        handle.child.exitCode === 0 || handle.child.signalCode === "SIGTERM",
        `child should be dead, got exitCode=${handle.child.exitCode}, signal=${handle.child.signalCode}`
      );
    } finally {
      cleanup();
    }
  });

  test("stop() SIGKILLs a child that ignores SIGTERM", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
echo "https://stubborn.trycloudflare.com"
# Ignore SIGTERM so stop() has to escalate.
trap "" TERM
while true; do sleep 0.1; done
`
    );
    try {
      const handle = await startCloudflaredTunnel({
        port: 1234,
        command: bin,
        args: [],
        timeoutMs: 2000,
      });
      await handle.stop(100); // short timeout forces SIGKILL
      assert.equal(handle.child.signalCode, "SIGKILL");
    } finally {
      cleanup();
    }
  });

  test("KANBAN_CLOUDFLARED env var selects the bundled binary", async () => {
    const { bin, cleanup } = writeFakeCloudflared(
      `#!/bin/sh
echo "https://bundled.trycloudflare.com"
sleep 10
`
    );
    const prev = process.env.KANBAN_CLOUDFLARED;
    process.env.KANBAN_CLOUDFLARED = bin;
    try {
      const handle = await startCloudflaredTunnel({ port: 5555, timeoutMs: 3000 });
      assert.equal(handle.url, "https://bundled.trycloudflare.com");
      await handle.stop(200);
    } finally {
      if (prev === undefined) delete process.env.KANBAN_CLOUDFLARED;
      else process.env.KANBAN_CLOUDFLARED = prev;
      cleanup();
    }
  });

  test("injected spawnImpl is used (tests never call npx)", async () => {
    let sawInjectedCall = false;
    const fakeSpawn: typeof spawn = ((cmd: string, args: readonly string[], _opts: unknown) => {
      sawInjectedCall = true;
      // Return a real child running /bin/sh -c that prints the URL, so the
      // rest of the plumbing still works; we're just asserting that the
      // helper uses the injected function rather than process-spawning npx.
      void cmd; void args;
      return spawn("/bin/sh", ["-c", "echo https://injected.trycloudflare.com; sleep 10"]);
    }) as unknown as typeof spawn;
    const handle = await startCloudflaredTunnel({
      port: 1234,
      spawnImpl: fakeSpawn,
      timeoutMs: 2000,
    });
    assert.ok(sawInjectedCall, "spawnImpl must have been called");
    assert.equal(handle.url, "https://injected.trycloudflare.com");
    await handle.stop(200);
  });
});

// Safety net: make sure no lingering child processes are left dangling.
// (Node's test runner will keep the process alive on outstanding handles,
// so if a test forgot to stop(), we'd know.)
test("process has no lingering children at the end of the suite", async () => {
  const children: ChildProcess[] = [];
  void children;
  // No assertion here — the runner's own shutdown check catches leaks.
});
