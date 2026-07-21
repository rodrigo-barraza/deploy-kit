// Cloudflare DNS provider — https://developers.cloudflare.com/api/
// Secret: CLOUDFLARE_API_TOKEN (env or vault) — a scoped token with
// Zone → DNS → Edit on the zones you want managed (NOT the global API key).

const { getSecret } = require("./provider.js");

const API_BASE = "https://api.cloudflare.com/client/v4";
const zoneIdCache = new Map();

async function call(endpoint, options = {}) {
  const token = await getSecret("CLOUDFLARE_API_TOKEN");
  if (!token) {
    throw new Error(
      "Cloudflare credentials missing — set CLOUDFLARE_API_TOKEN in the environment " +
        "or the vault (scoped token: Zone → DNS → Edit).",
    );
  }
  const response = await fetch(`${API_BASE}${endpoint}`, {
    ...options,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || json.success === false) {
    const message = (json.errors || []).map((e) => e.message).join("; ") || `HTTP ${response.status}`;
    throw new Error(`Cloudflare ${endpoint} failed: ${message}`);
  }
  return json;
}

async function zoneId(zone) {
  if (zoneIdCache.has(zone)) return zoneIdCache.get(zone);
  const json = await call(`/zones?name=${encodeURIComponent(zone)}`);
  const id = json.result?.[0]?.id;
  if (!id) throw new Error(`Cloudflare: zone "${zone}" not found on this account/token`);
  zoneIdCache.set(zone, id);
  return id;
}

/** Cloudflare names are fully qualified; normalize to the subdomain part. */
function toSubdomain(fullyQualifiedName, zone) {
  if (fullyQualifiedName === zone) return "";
  return fullyQualifiedName.endsWith(`.${zone}`)
    ? fullyQualifiedName.slice(0, -(zone.length + 1))
    : fullyQualifiedName;
}

module.exports = {
  name: "cloudflare",
  caddyPlugin: "github.com/caddy-dns/cloudflare",
  caddyTlsLines: ["dns cloudflare {env.CLOUDFLARE_API_TOKEN}"],
  requiredEnv: ["CLOUDFLARE_API_TOKEN"],

  async listRecords(zone) {
    const id = await zoneId(zone);
    const json = await call(`/zones/${id}/dns_records?per_page=200`);
    return (json.result || []).map((record) => ({
      id: record.id,
      name: toSubdomain(record.name, zone),
      type: record.type,
      content: record.content,
      ttl: record.ttl,
    }));
  },

  async createRecord(zone, { name, type, content, ttl = 300 }) {
    const id = await zoneId(zone);
    const fullyQualified = name ? `${name}.${zone}` : zone;
    const json = await call(`/zones/${id}/dns_records`, {
      method: "POST",
      body: JSON.stringify({ name: fullyQualified, type, content, ttl, proxied: false }),
    });
    return json.result.id;
  },

  async updateRecord(zone, recordId, { name, type, content, ttl = 300 }) {
    const id = await zoneId(zone);
    const fullyQualified = name ? `${name}.${zone}` : zone;
    await call(`/zones/${id}/dns_records/${recordId}`, {
      method: "PUT",
      body: JSON.stringify({ name: fullyQualified, type, content, ttl, proxied: false }),
    });
  },

  async deleteRecord(zone, recordId) {
    const id = await zoneId(zone);
    await call(`/zones/${id}/dns_records/${recordId}`, { method: 'DELETE' });
  },

  async getPublicIp() {
    const response = await fetch("https://api.ipify.org?format=json");
    return (await response.json()).ip;
  },
};
