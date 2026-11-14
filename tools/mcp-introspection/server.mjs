#!/usr/bin/env node
// Answers MCP introspection (initialize, tools/list) from the same tool definitions the apps serve, so directories
// that check servers in a Linux container can list Native Screen's tools. The real server is the app itself
// (`Native Screen --mcp`, see docs); every tool call here fails with a pointer to it.

import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const manifestPath = process.env.NATIVESCREEN_MCP_TOOLS ?? join(here, "../../macos/NativeScreen/Resources/MCPTools.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

// Clients do not resolve `$ref` across files, so shared definitions are inlined, as the apps do.
function inline(value) {
  if (Array.isArray(value)) return value.map(inline);
  if (value && typeof value === "object") {
    const ref = value.$ref;
    if (typeof ref === "string" && ref.startsWith("#/definitions/")) {
      const resolved = manifest.definitions?.[ref.slice("#/definitions/".length)];
      if (resolved) return resolved;
    }
    return Object.fromEntries(Object.entries(value).map(([key, inner]) => [key, inline(inner)]));
  }
  return value;
}

const tools = (manifest.tools ?? []).map(inline);
const supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"];
const notInstalled =
  "This is the introspection-only Native Screen MCP server. Tools run inside the Native Screen app on macOS or " +
  "Windows: install it from https://nativescreen.app, turn on Settings > AI Agents, and point your client at " +
  "`Native Screen --mcp` (setup: https://github.com/maitrungduc1410/NativeScreen#let-an-ai-agent-drive-it).";

function send(message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}

function handle(message) {
  const { id, method, params = {} } = message;
  if (!method) return; // a response to a request we never send
  const reply = (result) => id !== undefined && send({ id, result });
  switch (method) {
    case "initialize": {
      const requested = params.protocolVersion;
      reply({
        protocolVersion: supportedVersions.includes(requested) ? requested : supportedVersions[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "nativescreen", title: "Native Screen", version: "introspection" },
        instructions: `${notInstalled}\n\n${manifest.instructions ?? ""}`,
      });
      break;
    }
    case "ping":
      reply({});
      break;
    case "tools/list":
      reply({ tools });
      break;
    case "tools/call":
      reply({ content: [{ type: "text", text: notInstalled }], isError: true });
      break;
    case "resources/list":
      reply({ resources: [] });
      break;
    case "prompts/list":
      reply({ prompts: [] });
      break;
    default:
      if (id !== undefined) send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
  }
}

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    send({ id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }
  handle(message);
});
