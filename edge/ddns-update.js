// DDNS: keep the single anchor A record pointed at the current public IP.
// Because every other managed hostname is CNAME → anchor, this one update
// migrates the whole fleet after an ISP IP change.
//
// Intended to run on a schedule (NAS cron / Task Scheduler, e.g. every 5m):
//   node /volume1/docker/edge/ddns-update.js
// Exits 0 quietly when nothing changed. Requires enabled:true to write.

const fs = require("fs");
const path = require("path");
const { loadProvider, zoneForDomain } = require("./dns/provider.js");

const EDGE_DIR = __dirname;
const config = JSON.parse(fs.readFileSync(path.join(EDGE_DIR, "edge.config.json"), "utf8"));

async function main() {
  const provider = loadProvider(config.dnsProvider);
  const anchor = config.anchorRecord;
  if (!anchor) throw new Error("edge.config.json anchorRecord is required");

  const zone = zoneForDomain(anchor, config.zoneOverrides || {});
  const subdomain = anchor === zone ? "" : anchor.slice(0, -(zone.length + 1));

  const publicIp = await provider.getPublicIp();
  const records = await provider.listRecords(zone);
  const anchorRecord = records.find((r) => r.name === subdomain && r.type === "A");

  if (!anchorRecord) {
    console.error(`Anchor A record ${anchor} does not exist — run reconcile-dns.js first.`);
    process.exit(1);
  }
  if (anchorRecord.content === publicIp) return; // quiet no-op

  if (!config.enabled) {
    console.log(`IP drift detected (${anchorRecord.content} → ${publicIp}) but enabled:false — not writing.`);
    process.exit(1);
  }
  await provider.updateRecord(zone, anchorRecord.id, {
    name: subdomain, type: "A", content: publicIp, ttl: anchorRecord.ttl,
  });
  console.log(`${new Date().toISOString()} updated ${anchor}: ${anchorRecord.content} → ${publicIp}`);
}

main().catch((error) => { console.error(error.message); process.exit(1); });
