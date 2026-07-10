import { describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { buildRequest } from "../src/client.js";
import type { ActionResult, AppState, ListAppsResult } from "../src/types.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(
  fs.readFileSync(path.join(here, "..", "..", "contracts", "fixtures.json"), "utf8"),
) as {
  requests: { method: string; params: unknown; line: string }[];
  responses: { name: string; decodes_to: string; json: unknown }[];
  json_values: { kind: string; json: unknown }[];
};

describe("contract", () => {
  it("buildRequest reproduces every request fixture line (modulo key order)", () => {
    for (const req of fixtures.requests) {
      const built = JSON.parse(buildRequest(1, req.method, req.params));
      expect(built).toEqual(JSON.parse(req.line));
    }
  });

  it("response fixtures satisfy the declared TS result types", () => {
    for (const resp of fixtures.responses) {
      if (resp.decodes_to === "ListAppsResult") {
        const r = resp.json as ListAppsResult;
        expect(Array.isArray(r.apps)).toBe(true);
        expect(typeof r.apps[0].pid).toBe("number");
        expect(typeof r.apps[0].is_frontmost).toBe("boolean");
      } else if (resp.decodes_to === "AppState") {
        const r = resp.json as AppState;
        expect(typeof r.text).toBe("string");
        if (r.screenshot != null) expect(typeof r.screenshot.url).toBe("string");
        else expect(typeof r.screenshot_error).toBe("string");
        expect(typeof r.diffed).toBe("boolean");
      } else if (resp.decodes_to === "ActionResult") {
        const r = resp.json as ActionResult;
        expect(typeof r.done).toBe("boolean");
      } else {
        throw new Error(`unhandled result type ${resp.decodes_to}`);
      }
    }
  });

  // Mirrors the Swift-side JSONValue coverage gap noted in Task 2's review:
  // .null/.number/.string/.array lacked direct round-trip assertions. These
  // fixtures are shared so both sides exercise the same literal values.
  it("covers the null/number/string/array JSON value kinds", () => {
    for (const item of fixtures.json_values) {
      if (item.kind === "null") expect(item.json).toBeNull();
      else if (item.kind === "number") expect(typeof item.json).toBe("number");
      else if (item.kind === "string") expect(typeof item.json).toBe("string");
      else if (item.kind === "array") expect(Array.isArray(item.json)).toBe(true);
      else throw new Error(`unhandled kind ${item.kind}`);

      expect(JSON.parse(JSON.stringify(item.json))).toEqual(item.json);
    }
  });
});
