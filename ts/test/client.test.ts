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
});
