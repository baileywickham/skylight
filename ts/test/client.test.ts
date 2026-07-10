import { afterEach, describe, expect, it } from "vitest";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { SkyClient, SkyError, buildRequest, defaultConfig } from "../src/client.js";

function tmpSock(): string {
  return path.join(os.tmpdir(), `sky-test-${Math.floor(Math.random() * 1e9)}.sock`);
}

/** Stub daemon: answers ping, echoes echo, fails anything else with a structured error. */
function stubServer(sockPath: string): Promise<net.Server> {
  const server = net.createServer((conn) => {
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        const req = JSON.parse(line);
        let resp: unknown;
        if (req.method === "ping") resp = { id: req.id, ok: true, result: { pong: true } };
        else if (req.method === "echo") resp = { id: req.id, ok: true, result: req.params };
        else resp = { id: req.id, ok: false, error: { code: "unknown_method", message: `unknown method '${req.method}'` } };
        conn.write(JSON.stringify(resp) + "\n");
      }
    });
  });
  return new Promise((resolve) => server.listen(sockPath, () => resolve(server)));
}

describe("SkyClient", () => {
  const servers: net.Server[] = [];
  const clients: SkyClient[] = [];
  afterEach(() => {
    for (const c of clients.splice(0)) c.close();
    for (const s of servers.splice(0)) s.close();
  });

  it("has the documented default config", () => {
    const cfg = defaultConfig();
    expect(cfg.socket_path.endsWith("Library/Application Support/skylight/ipc/computeruse.sock")).toBe(true);
    expect(cfg.post_action_sleep_ms).toBe(100);
    expect(cfg.shots_dir.endsWith(path.join(".skylight", "shots"))).toBe(true);
  });

  it("serializes requests as one JSON object per line", () => {
    expect(JSON.parse(buildRequest(3, "click", { app: "Notes", element_index: 12 }))).toEqual({
      id: 3,
      method: "click",
      params: { app: "Notes", element_index: 12 },
    });
    expect(buildRequest(1, "ping", undefined)).not.toContain("\n");
  });

  it("connects lazily and round-trips a call", async () => {
    const sock = tmpSock();
    servers.push(await stubServer(sock));
    const client = new SkyClient({ socket_path: sock });
    clients.push(client);
    const result = await client.call<{ pong: boolean }>("ping", {});
    expect(result.pong).toBe(true);
    const echoed = await client.call<{ app: string }>("echo", { app: "Notes" });
    expect(echoed.app).toBe("Notes");
  });

  it("rejects with SkyError carrying the structured code", async () => {
    const sock = tmpSock();
    servers.push(await stubServer(sock));
    const client = new SkyClient({ socket_path: sock });
    clients.push(client);
    await expect(client.call("warp_drive", {})).rejects.toMatchObject({
      name: "SkyError",
      code: "unknown_method",
    });
    await expect(client.call("warp_drive", {})).rejects.toBeInstanceOf(SkyError);
  });

  it("rejects every concurrent call (not just the oldest) on an id:0 protocol error, then hangs up", async () => {
    const sock = tmpSock();
    // Stub daemon that mimics the Swift daemon's protocol-error behavior:
    // never answer per-request, just send one unmatched id:0 error frame and
    // then close the socket -- exactly what happens on an oversized/unparseable
    // request line.
    const server = net.createServer((conn) => {
      conn.on("data", () => {
        conn.write(JSON.stringify({ id: 0, ok: false, error: { code: "protocol_error", message: "request line too long" } }) + "\n");
        conn.end();
      });
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(sock, () => resolve()));

    const client = new SkyClient({ socket_path: sock });
    clients.push(client);

    const [pingResult, echoResult] = await Promise.allSettled([
      client.call("ping", {}),
      client.call("echo", { app: "Notes" }),
    ]);

    expect(pingResult.status).toBe("rejected");
    expect(echoResult.status).toBe("rejected");
    if (pingResult.status === "rejected") {
      expect(pingResult.reason).toBeInstanceOf(SkyError);
      expect(pingResult.reason).toMatchObject({ code: "protocol_error" });
    }
    if (echoResult.status === "rejected") {
      expect(echoResult.reason).toBeInstanceOf(SkyError);
      expect(echoResult.reason).toMatchObject({ code: "protocol_error" });
    }
  }, 5000);

  it("rejects still-pending calls when the socket drops without any response", async () => {
    const sock = tmpSock();
    // Stub daemon that accepts the connection and then closes it immediately
    // without ever writing a response -- simulates a mid-flight socket drop.
    const server = net.createServer((conn) => {
      conn.on("data", () => conn.end());
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(sock, () => resolve()));

    const client = new SkyClient({ socket_path: sock });
    clients.push(client);

    await expect(client.call("ping", {})).rejects.toBeInstanceOf(SkyError);
  }, 5000);

  it("close() settles outstanding calls instead of leaving them hanging", async () => {
    const sock = tmpSock();
    // Stub daemon that accepts connections but never responds, so the call
    // stays pending until close() is invoked.
    const server = net.createServer(() => {});
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(sock, () => resolve()));

    const client = new SkyClient({ socket_path: sock });
    clients.push(client);

    const pending = client.call("ping", {});
    // Give the connection a tick to establish before closing.
    await new Promise((resolve) => setTimeout(resolve, 50));
    client.close();

    await expect(pending).rejects.toThrow();
  }, 5000);
});
