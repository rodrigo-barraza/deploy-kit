// DDNS: keep every MANAGED A record pointed at the current public IP.
// That's the anchor plus zone apexes / foreign-zone domains (which can't
// CNAME to the anchor) — each updated through its own zone's DNS provider.
// CNAMEs never need touching.
//
// Intended to run on a schedule (NAS cron / Task Scheduler, e.g. every 5m):
//   node /volume1/docker/edge/ddns-update.js
// Exits 0 quietly when nothing changed. Requires enabled:true to write.

const fs = require("fs");
const path = require("path");
const { providerForZone, planRecords } = require("./dns/provider.js");

const EDGE_DIR = __dirname;
const ROOT_DIR = path.join(EDGE_DIR, "..", "..");
const registry = JSON.parse(fs.readFileSync(process.env.PROJECTS_JSON_PATH || path.join(ROOT_DIR, "vault-service", "projects.json"), "utf8"));
const config = require("./edge-config.js").loadEdgeConfig();

async function main() {
  const anchor = config.anchorRecord;
  if (!anchor) throw new Error("edge config anchorRecord is required");

  const domains = registry.projects
    .filter((p) => p.visibility === "external" && p.domain)
    .map((p) => p.domain)
    .concat((config.extraSites || []).map((s) => s.domain));

  const aRecordPlan = planRecords(domains, anchor, config).filter((e) => e.contentKind === "publicIp");
  const publicIp = await providerForZone("", { ...config, zoneProviders: {} }).getPublicIp();

  const byZone = new Map();
  for (const entry of aRecordPlan) {
    if (!byZone.has(entry.zone)) byZone.set(entry.zone, []);
    byZone.get(entry.zone).push(entry);
  }

  let stale = 0, updated = 0;
  for (const [zone, zonePlan] of byZone) {
    const provider = providerForZone(zone, config);
    let records;
    try {
      records = await provider.listRecords(zone);
    } catch (error) {
      console.error(`zone ${zone} (${provider.name}): ${error.message}`);
      continue;
    }
    for (const entry of zonePlan) {
      const record = records.find((r) => r.name === entry.name && r.type === "A");
      if (!record || record.content === publicIp) continue;
      stale++;
      if (!config.enabled) {
        console.log(`IP drift: ${entry.domain} ${record.content} → ${publicIp} (enabled:false — not writing)`);
        continue;
      }
      await provider.updateRecord(zone, record.id, {
        name: entry.name, type: "A", content: publicIp, ttl: record.ttl,
      });
      updated++;
      console.log(`${new Date().toISOString()} updated ${entry.domain}: ${record.content} → ${publicIp}`);
    }
  }

  if (stale && !config.enabled) process.exit(1);
  if (stale && updated < stale) process.exit(1);
}

main().catch((error) => { console.error(error.message); process.exit(1); });
