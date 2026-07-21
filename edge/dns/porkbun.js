// Porkbun DNS provider — https://porkbun.com/api/json/v3/documentation
// Secrets: PORKBUN_API_KEY + PORKBUN_API_SECRET_KEY (env or vault).

const { getSecret } = require("./provider.js");

const API_BASE = "https://api.porkbun.com/api/json/v3";

async function credentials() {
  const apikey = await getSecret("PORKBUN_API_KEY");
  const secretapikey = await getSecret("PORKBUN_API_SECRET_KEY");
  if (!apikey || !secretapikey) {
    throw new Error(
      "Porkbun credentials missing — set PORKBUN_API_KEY and PORKBUN_API_SECRET_KEY " +
        "in the environment or the vault. (Porkbun also requires API access to be " +
        "toggled ON per-domain in its dashboard.)",
    );
  }
  return { apikey, secretapikey };
}

async function call(endpoint, body = {}) {
  const auth = await credentials();
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ...auth, ...body }),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || json.status !== "SUCCESS") {
    throw new Error(`Porkbun ${endpoint} failed: ${json.message || response.status}`);
  }
  return json;
}

/** Porkbun returns fully-qualified names; normalize to the subdomain part. */
function toSubdomain(fullyQualifiedName, zone) {
  if (fullyQualifiedName === zone) return "";
  return fullyQualifiedName.endsWith(`.${zone}`)
    ? fullyQualifiedName.slice(0, -(zone.length + 1))
    : fullyQualifiedName;
}

module.exports = {
  name: "porkbun",
  caddyPlugin: "github.com/caddy-dns/porkbun",
  caddyTlsLines: [
    "dns porkbun {",
    "\tapi_key {env.PORKBUN_API_KEY}",
    "\tapi_secret_key {env.PORKBUN_API_SECRET_KEY}",
    "}",
  ],
  requiredEnv: ["PORKBUN_API_KEY", "PORKBUN_API_SECRET_KEY"],

  async listRecords(zone) {
    const json = await call(`/dns/retrieve/${zone}`);
    return (json.records || []).map((record) => ({
      id: record.id,
      name: toSubdomain(record.name, zone),
      type: record.type,
      content: record.content,
      ttl: Number(record.ttl) || 600,
    }));
  },

  async createRecord(zone, { name, type, content, ttl = 600 }) {
    const json = await call(`/dns/create/${zone}`, { name, type, content, ttl: String(ttl) });
    return json.id;
  },

  async updateRecord(zone, id, { name, type, content, ttl = 600 }) {
    await call(`/dns/edit/${zone}/${id}`, { name, type, content, ttl: String(ttl) });
  },

  async getPublicIp() {
    const json = await call("/ping");
    return json.yourIp;
  },
};
