export * from "./types.js";
export { SkyClient, SkyError, defaultConfig, loadConfig, buildRequest } from "./client.js";
export type { SkyConfig } from "./client.js";
import { SkyClient } from "./client.js";

/** Shared lazy-connecting singleton, mirroring @oai/sky usage: `import { sky } from "@skylight/sky"`. */
export const sky = new SkyClient();
