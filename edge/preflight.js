// Preflight: assert every registry domain works THROUGH the edge proxy —
// TLS handshake with the domain's SNI, healthPath status, and (for
// configured domains) a real WebSocket 101 upgrade. This exercises the
// exact leg previous "prod-verified" testing skipped.
//
// Usage:
//   node edge/preflight.js                 # against Caddy on deploy device:httpsPort
//   node edge/preflight.js --host 1.2.3.4 --port 443   # against anything (e.g. post-cutover)
//
// tlsMode:"internal" (or --insecure) skips certificate verification.

const fs = require("fs");
const path = require("path");
const tls = require("tls");
const crypto = require("crypto");

const EDGE_DIR = __dirname;
const ROOT_DIR = path.join(EDGE_DIR, "..", "..");
const registry = JSON.parse(fs.readFileSync(process.env.PROJECTS_JSON_PATH || path.join(ROOT_DIR, "vault-service", "projects.json"), "utf8"));
const config = require("./edge-config.js").loadEdgeConfig();

const args = process.argv.slice(2);
const argValue = (flag, fallback) => {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : fallback;
};

const deviceHosts = Object.fromEntries((registry.devices || []).map((d) => [d.id, d.hostname]));
// proxyMode "caddy": test the (not yet public) Caddy container on the NAS.
// proxyMode "dsm" (or any hand-managed proxy): test each domain's PUBLIC
// endpoint — DNS resolves the host, port 443, real cert verification.
const isDsmMode = config.proxyMode === "dsm";
const targetHost = argValue("--host", isDsmMode ? null : deviceHosts[config.deployDevice] || registry.defaultHost);
const targetPort = Number(argValue("--port", isDsmMode ? 443 : config.httpsPort));
const insecure = args.includes("--insecure") || (!isDsmMode && config.tlsMode === "internal");
const timeoutMs = 10_000;

const sites = registry.projects
  .filter((p) => p.visibility === "external" && p.domain && p.port)
  .map((p) => ({ domain: p.domain, healthPath: p.healthPath || "/", source: p.id }));
for (const extra of config.extraSites || []) {
  sites.push({ domain: extra.domain, healthPath: extra.healthPath || "/", source: "extraSites" });
}

/** Raw HTTP/1.1 request over TLS with explicit SNI, so we can also do WS upgrades. */
function rawTlsRequest(domain, requestLines) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect(
      // targetHost null (dsm mode) → connect to the domain itself via DNS
      { host: targetHost || domain, port: targetPort, servername: domain, rejectUnauthorized: !insecure },
      () => socket.write(requestLines.join("\r\n") + "\r\n\r\n"),
    );
    let response = "";
    const timer = setTimeout(() => { socket.destroy(); reject(new Error("timeout")); }, timeoutMs);
    socket.on("data", (chunk) => {
      response += chunk.toString("utf8");
      if (response.includes("\r\n\r\n")) { clearTimeout(timer); socket.end(); resolve(response); }
    });
    socket.on("error", (error) => { clearTimeout(timer); reject(error); });
    socket.on("close", () => { clearTimeout(timer); resolve(response); });
  });
}

async function checkHealth({ domain, healthPath }) {
  const response = await rawTlsRequest(domain, [
    `GET ${healthPath} HTTP/1.1`,
    `Host: ${domain}`,
    "User-Agent: edge-preflight",
    "Connection: close",
  ]);
  const status = Number((response.match(/^HTTP\/[\d.]+ (\d+)/) || [])[1] || 0);
  if (status === 0) throw new Error("no HTTP response");
  if (status >= 500) throw new Error(`HTTP ${status}`);
  return `HTTP ${status}`;
}

async function checkWebSocket({ domain, path: wsPath }) {
  const key = crypto.randomBytes(16).toString("base64");
  const response = await rawTlsRequest(domain, [
    `GET ${wsPath} HTTP/1.1`,
    `Host: ${domain}`,
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Key: ${key}`,
    "Sec-WebSocket-Version: 13",
  ]);
  const status = Number((response.match(/^HTTP\/[\d.]+ (\d+)/) || [])[1] || 0);
  if (status !== 101) {
    throw new Error(`expected 101 Switching Protocols, got HTTP ${status || "∅"} — upgrade headers are being dropped`);
  }
  return "101 upgrade OK";
}

async function main() {
  console.log(`Preflight against ${targetHost || "each domain's public endpoint"}:${targetPort} (proxyMode=${config.proxyMode || "caddy"}, insecure=${insecure}) — ${sites.length} sites\n`);
  let failures = 0;

  for (const site of sites) {
    try {
      const result = await checkHealth(site);
      console.log(`  ✔ ${site.domain.padEnd(34)} ${result}`);
    } catch (error) {
      failures++;
      console.log(`  ✘ ${site.domain.padEnd(34)} ${error.message}`);
    }
  }

  console.log("");
  for (const wsCheck of config.wsChecks || []) {
    try {
      const result = await checkWebSocket(wsCheck);
      console.log(`  ✔ WS ${wsCheck.domain.padEnd(31)} ${result}`);
    } catch (error) {
      failures++;
      console.log(`  ✘ WS ${wsCheck.domain.padEnd(31)} ${error.message}`);
    }
  }

  console.log(failures ? `\n${failures} FAILURE(S)` : "\nAll checks passed.");
  process.exit(failures ? 1 : 0);
}

main();
