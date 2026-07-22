// Single loader for edge settings, layered like the vault:
//
//   deploy-kit/edge/edge.config.json   — committed defaults / template
//   vault-service/projects.json "edge" — private overrides, WINS (registry
//                                        stays the source of truth)
//
// Every edge script reads config through this, so a setting flipped in
// projects.json (e.g. { "edge": { "enabled": true, "proxyMode": "caddy" } })
// takes effect everywhere without touching the committed defaults.

const fs = require("fs");
const path = require("path");

const EDGE_DIR = __dirname;
const ROOT_DIR = path.join(EDGE_DIR, "..", "..");
const PROJECTS_JSON = process.env.PROJECTS_JSON_PATH || path.join(ROOT_DIR, "vault-service", "projects.json");
const DEFAULTS_PATH = path.join(EDGE_DIR, "edge.config.json");

function stripComments(object) {
  const cleaned = {};
  for (const [key, value] of Object.entries(object)) {
    if (!key.startsWith("$")) cleaned[key] = value;
  }
  return cleaned;
}

function loadEdgeConfig() {
  const defaults = stripComments(JSON.parse(fs.readFileSync(DEFAULTS_PATH, "utf8")));
  let overrides = {};
  try {
    const registry = JSON.parse(fs.readFileSync(PROJECTS_JSON, "utf8"));
    overrides = stripComments(registry.edge || {});
  } catch {
    // No registry (external user without a vault) — defaults alone apply.
  }
  const merged = { ...defaults, ...overrides };
  merged._overriddenKeys = Object.keys(overrides);
  return merged;
}

module.exports = { loadEdgeConfig };
