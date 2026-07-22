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

/**
 * Provider for a zone: config.zoneProviders["clankerbox.com"] = "cloudflare"
 * wins; otherwise the global config.dnsProvider default. Domains can live at
 * different registrars — each zone talks to its own provider.
 */
function providerForZone(zone, config) {
  const name = (config.zoneProviders || {})[zone] || config.dnsProvider;
  return loadProvider(name);
}

/**
 * The record plan shared by reconcile-dns.js (create missing) and
 * ddns-update.js (repoint stale A records on IP change).
 *
 * With an anchor (anchorRecord set):
 *   anchor + zone apexes + anything outside the anchor's zone → A record @ public IP
 *   subdomains inside the anchor's zone → CNAME → anchor
 * Without an anchor (anchorRecord null): every domain → A record @ public IP
 * (simpler; DDNS then rewrites each one on an IP change instead of just the anchor).
 */
function planRecords(domains, anchor, config) {
  const zoneOverrides = config.zoneOverrides || {};
  const anchorZone = anchor ? zoneForDomain(anchor, zoneOverrides) : null;
  const plan = [];
  for (const domain of new Set([...(anchor ? [anchor] : []), ...domains])) {
    const zone = zoneForDomain(domain, zoneOverrides);
    const name = domain === zone ? "" : domain.slice(0, -(zone.length + 1));
    const isARecord = !anchor || domain === anchor || name === "" || zone !== anchorZone;
    plan.push({
      domain,
      zone,
      name,
      type: isARecord ? "A" : "CNAME",
      contentKind: isARecord ? "publicIp" : "anchor",
    });
  }
  return plan;
}

/**
 * The IP all managed A records should carry.
 *
 * config.publicIp: "auto" (dynamic connection — detect the egress IP each
 * run) or an explicit IP (static connection — the declared value is the
 * source of truth). In static mode the egress IP is still detected
 * best-effort purely to WARN when reality disagrees with the declaration
 * (ISP silently changed a "static" IP, or you're running from elsewhere).
 */
async function resolvePublicIp(config, provider) {
  const declared = config.publicIp && config.publicIp !== "auto" ? config.publicIp : null;
  let detected = null;
  try {
    detected = await provider.getPublicIp();
  } catch (error) {
    if (!declared) throw error; // dynamic mode cannot proceed without detection
  }
  if (declared && detected && detected !== declared) {
    console.warn(
      `⚠ Declared static publicIp ${declared} but current egress IP is ${detected} — ` +
        `records follow the DECLARED value; update the registry if the static IP really changed.`,
    );
  }
  return { ip: declared || detected, mode: declared ? "static" : "dynamic", detected };
}

module.exports = { loadProvider, getSecret, zoneForDomain, providerForZone, planRecords, resolvePublicIp };
