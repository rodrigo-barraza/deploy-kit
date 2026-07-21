// No-op DNS provider — for setups that manage DNS by hand or use a
// provider without an implementation here. DNS-01 certs are unavailable,
// so Caddy falls back to HTTP-01 (public port 80 must reach Caddy).

const fail = (operation) => {
  throw new Error(
    `dnsProvider is "none" — ${operation} is unavailable. ` +
      `Set "dnsProvider" in edge/edge.config.json to a module in edge/dns/ ` +
      `(or implement one for your registrar; see edge/dns/provider.js).`,
  );
};

module.exports = {
  name: "none",
  caddyPlugin: null,
  caddyTlsLines: [],
  requiredEnv: [],
  async listRecords() { return fail("listRecords"); },
  async createRecord() { return fail("createRecord"); },
  async updateRecord() { return fail("updateRecord"); },
  async getPublicIp() {
    const response = await fetch("https://api.ipify.org?format=json");
    return (await response.json()).ip;
  },
};
