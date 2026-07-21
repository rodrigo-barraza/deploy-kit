// DNS provider abstraction for the edge module.
//
// A provider is a module in edge/dns/<name>.js exporting:
//
//   module.exports = {
//     name: "porkbun",
//     // Caddy integration — how DNS-01 certs are wired for this provider:
//     caddyPlugin: "github.com/caddy-dns/porkbun",  // xcaddy --with value, or null
//     caddyTlsLines: ["dns porkbun {env.PORKBUN_API_KEY} {env.PORKBUN_API_SECRET_KEY}"],
//     requiredEnv: ["PORKBUN_API_KEY", "PORKBUN_API_SECRET_KEY"],
//     // Record management (all zone-scoped; `name` is the subdomain part, "" for apex):
//     async listRecords(zone) -> [{ id, name, type, content, ttl }]
//     async createRecord(zone, { name, type, content, ttl }) -> id
//     async updateRecord(zone, id, { name, type, content, ttl }) -> void
//     async getPublicIp() -> "1.2.3.4"
//   }
//
// Secrets are resolved from process.env first, then the vault service —
// nothing provider-specific is hardcoded outside its own module.

const fs = require("fs");
const path = require("path");

function loadProvider(name) {
  if (!name || name === "none") return require("./none.js");
  const providerPath = path.join(__dirname, `${name}.js`);
  if (!fs.existsSync(providerPath)) {
    const available = fs
      .readdirSync(__dirname)
      .filter((f) => f.endsWith(".js") && f !== "provider.js")
      .map((f) => f.replace(/\.js$/, ""));
    throw new Error(
      `Unknown dnsProvider "${name}" — available: ${available.join(", ")}. ` +
        `Implement edge/dns/${name}.js (interface documented in edge/dns/provider.js).`,
    );
  }
  return require(providerPath);
}

/**
 * Resolve a secret: process.env first, then the vault service (token from
 * vault-service/vault.key next to this repo). Returns null when unresolvable.
 */
async function getSecret(name) {
  if (process.env[name]) return process.env[name];
  try {
    const vaultUrl = process.env.VAULT_SERVICE_URL || "http://192.168.86.2:5599";
    const keyPath = path.join(__dirname, "..", "..", "..", "vault-service", "vault.key");
    const token = fs.readFileSync(keyPath, "utf8").trim();
    const response = await fetch(`${vaultUrl}/secrets`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!response.ok) return null;
    const secrets = await response.json();
    return secrets[name] || null;
  } catch {
    return null;
  }
}

/** Zone (registrable domain) for a hostname — overridable via config.zoneOverrides. */
function zoneForDomain(domain, zoneOverrides = {}) {
  if (zoneOverrides[domain]) return zoneOverrides[domain];
  const labels = domain.split(".");
  return labels.slice(-2).join(".");
}

module.exports = { loadProvider, getSecret, zoneForDomain };
