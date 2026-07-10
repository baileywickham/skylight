import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type {
  ActionResult, AppState, ClickInput, DragInput, GetAppStateInput, ListAppsResult,
  PerformSecondaryActionInput, PressKeyInput, ScrollInput, SelectTextInput,
  SetValueInput, TypeTextInput,
} from "./types.js";

// NOTE: shots_dir is intentionally NOT part of SkyConfig: the client never
// transmits configuration to the daemon, so a client-side shots_dir would be
// dead weight that looks functional. The daemon's shots dir is controlled by
// $SKYLIGHT_SHOTS_DIR in the daemon's environment (see the LaunchAgent plist),
// defaulting to ~/Library/Application Support/skylight/shots.
export interface SkyConfig {
  socket_path: string;
  post_action_sleep_ms: number;
}

export function defaultConfig(): SkyConfig {
  const support = path.join(os.homedir(), "Library", "Application Support", "skylight");
  return {
    socket_path: path.join(support, "ipc", "computeruse.sock"),
    post_action_sleep_ms: 100,
  };
}

/** Reads JSON config from $SKYLIGHT_CONFIG_PATH over the defaults. */
export function loadConfig(): SkyConfig {
  const cfg = defaultConfig();
  const p = process.env.SKYLIGHT_CONFIG_PATH;
  if (p && fs.existsSync(p)) Object.assign(cfg, JSON.parse(fs.readFileSync(p, "utf8")));
  return cfg;
}

export function buildRequest(id: number, method: string, params: unknown): string {
  return JSON.stringify({ id, method, params: params ?? {} });
}

export class SkyError extends Error {
  constructor(public readonly code: string, message: string) {
    super(message);
    this.name = "SkyError";
  }
}

interface WireResponse {
  id: number;
  ok: boolean;
  result?: unknown;
  error?: { code: string; message: string };
}

export class SkyClient {
  readonly config: SkyConfig;
  private socket: net.Socket | null = null;
  private connecting: Promise<net.Socket> | null = null;
  private nextId = 1;
  private buffer = "";
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();

  constructor(config?: Partial<SkyConfig>) {
    this.config = { ...loadConfig(), ...config };
  }

  /** Lazy connect on first call, like @oai/sky. */
  private connect(): Promise<net.Socket> {
    if (this.socket && !this.socket.destroyed) return Promise.resolve(this.socket);
    if (this.connecting) return this.connecting;
    this.connecting = new Promise((resolve, reject) => {
      const socket = net.createConnection(this.config.socket_path);
      socket.on("connect", () => {
        this.socket = socket;
        this.connecting = null;
        resolve(socket);
      });
      socket.on("error", (err) => {
        this.connecting = null;
        const wrapped = new SkyError(
          "connection_failed",
          `cannot reach SkylightService at ${this.config.socket_path} (run 'skylight start'): ${err.message}`,
        );
        this.rejectAllPending(wrapped);
        reject(wrapped);
      });
      socket.on("data", (chunk) => this.onData(chunk));
      socket.on("close", () => this.handleSocketTeardown(socket));
      socket.on("end", () => this.handleSocketTeardown(socket));
    });
    return this.connecting;
  }

  /** Rejects and clears every pending call with the same error. */
  private rejectAllPending(err: Error): void {
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
  }

  /**
   * Called when the socket closes/ends/errors out from under us (including
   * the FIN the daemon sends right after an id:0 protocol error). Fails any
   * still-pending calls instead of leaving them hanging forever, and resets
   * connection state so the next call() reconnects lazily.
   */
  private handleSocketTeardown(socket: net.Socket): void {
    // Only react to the socket we currently consider active: a socket that
    // failed before ever connecting is already handled by the "error"
    // listener above, and a stale/superseded socket's late "close"/"end"
    // must not clobber a newer in-flight reconnect.
    if (this.socket !== socket) return;
    this.socket = null;
    this.connecting = null;
    this.rejectAllPending(new SkyError("connection_closed", "connection to SkylightService closed unexpectedly"));
  }

  private onData(chunk: Buffer): void {
    this.buffer += chunk.toString("utf8");
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      if (!line.trim()) continue;
      let msg: WireResponse;
      try {
        msg = JSON.parse(line) as WireResponse;
      } catch {
        // A malformed frame must not throw out of the socket "data" event
        // handler (that would be an uncaught exception killing the process).
        // It also means the stream is corrupt, so fail every in-flight call.
        this.rejectAllPending(new SkyError(
          "protocol_error",
          `malformed response line from daemon: ${line.slice(0, 200)}`,
        ));
        continue;
      }
      const waiter = this.pending.get(msg.id);
      if (!waiter) {
        // Unmatched frame (e.g. protocol-level error reported with id: 0, or a
        // stray/duplicate response). Don't drop it silently and don't hang any
        // pending caller forever: surface it by failing every in-flight
        // request, since a protocol-level failure (e.g. an oversized/
        // malformed request line) invalidates the whole connection, not just
        // the oldest call.
        if (!msg.ok) {
          this.rejectAllPending(new SkyError(msg.error?.code ?? "protocol_error", msg.error?.message ?? "unmatched protocol error"));
        }
        continue;
      }
      this.pending.delete(msg.id);
      if (msg.ok) waiter.resolve(msg.result);
      else waiter.reject(new SkyError(msg.error?.code ?? "unknown", msg.error?.message ?? "unknown error"));
    }
  }

  async call<T>(method: string, params: unknown): Promise<T> {
    const socket = await this.connect();
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      socket.write(buildRequest(id, method, params) + "\n");
    });
  }

  close(): void {
    this.rejectAllPending(new SkyError("connection_closed", "SkyClient was closed"));
    this.socket?.destroy();
    this.socket = null;
    this.connecting = null;
  }

  list_apps(): Promise<ListAppsResult> { return this.call("list_apps", {}); }
  get_app_state(input: GetAppStateInput): Promise<AppState> { return this.call("get_app_state", input); }
  click(input: ClickInput): Promise<ActionResult> { return this.call("click", input); }
  press_key(input: PressKeyInput): Promise<ActionResult> { return this.call("press_key", input); }
  type_text(input: TypeTextInput): Promise<ActionResult> { return this.call("type_text", input); }
  scroll(input: ScrollInput): Promise<ActionResult> { return this.call("scroll", input); }
  set_value(input: SetValueInput): Promise<ActionResult> { return this.call("set_value", input); }
  drag(input: DragInput): Promise<ActionResult> { return this.call("drag", input); }
  perform_secondary_action(input: PerformSecondaryActionInput): Promise<ActionResult> {
    return this.call("perform_secondary_action", input);
  }
  select_text(input: SelectTextInput): Promise<ActionResult> { return this.call("select_text", input); }
}
