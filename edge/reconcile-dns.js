// DNS reconciler: ensure every registry domain resolves to home.
//
// Shape: one anchor A record (config.anchorRecord → current public IP);
// every other managed hostname is CNAME (subdomains) or ALIAS (zone apex)
// pointing at the anchor. An ISP IP change then touches ONE record
// (see ddns-update.js).
//
// SAFETY: additive + report only. Existing records are never modified or
// deleted — mismatches are reported for a human to resolve (MX/TXT/
// verification records you own by hand are invisible to this tool's writes).
//
// Usage:
//   node edge/reconcile-dns.js            # dry-run (always, when enabled:false)
//   node edge/reconcile-dns.js --apply    # create missing records (requires enabled:true)

const fs = require("fs");
const path = require("path");
const { loadProvider, zoneForDomain } = require("./dns/provider.js");

const EDGE_DIR = __dirname;
const ROOT_DIR = path.join(EDGE_DIR, "..", "..");
const registry = JSON.parse(fs.readFileSync(path.join(ROOT_DIR, "vault-service", "projects.json"), "utf8"));
const config = require("./edge-config.js").loadEdgeConfig();

const apply = process.argv.includes("--apply") && config.enabled;
if (process.argv.includes("--apply") && !config.enabled) {
  console.log("⚠ edge.config.json has enabled:false — forcing dry-run.\n");
}

async function main() {
  const provider = loadProvider(config.dnsProvider);
  const anchor = config.anchorRecord;
  if (!anchor) throw new Error("edge.config.json anchorRecord is required for DNS reconciliation");

  const domains = registry.projects
    .filter((p) => p.visibility === "external" && p.domain)
    .map((p) => p.domain)
    .concat((config.extraSites || []).map((s) => s.domain));

  const publicIp = await provider.getPublicIp();
  console.log(`Provider: ${provider.name} | public IP: ${publicIp} | anchor: ${anchor} | mode: ${apply ? "APPLY" : "dry-run"}\n`);

  // Group by zone; include the anchor itself.
  const byZone = new Map();
  const addToZone = (domain) => {
    const zone = zoneForDomain(domain, config.zoneOverrides || {});
    if (!byZone.has(zone)) byZone.set(zone, new Set());
    byZone.get(zone).add(domain);
  };
  addToZone(anchor);
  domains.forEach(addToZone);

  const anchorZone = zoneForDomain(anchor, config.zoneOverrides || {});
  let created = 0, ok = 0, conflicts = 0;

  for (const [zone, zoneDomains] of byZone) {
    let records;
    try {
      records = await provider.listRecords(zone);
    } catch (error) {
      console.log(`✘ zone ${zone}: ${error.message}`);
      conflicts++;
      continue;
    }
    const findRecord = (name) => records.filter((r) => r.name === name && ["A", "AAAA", "CNAME", "ALIAS"].includes(r.type));

    for (const domain of zoneDomains) {
      const subdomain = domain === zone ? "" : domain.slice(0, -(zone.length + 1));
      const isAnchor = domain === anchor;
      // Anchor → A record to public IP. Subdomains → CNAME to anchor.
      // Zone apexes (and anchors in foreign zones) can't CNAME → A record.
      const wanted = isAnchor || subdomain === "" || zone !== anchorZone
        ? { name: subdomain, type: "A", content: publicIp }
        : { name: subdomain, type: "CNAME", content: anchor };

      const existing = findRecord(subdomain);
      if (existing.length === 0) {
        console.log(`  + ${domain.padEnd(34)} ${wanted.type} → ${wanted.content}${apply ? "" : "  (dry-run)"}`);
        if (apply) await provider.createRecord(zone, wanted);
        created++;
      } else if (
        existing.some((r) =>
          (r.type === wanted.type && r.content === wanted.content) ||
          (r.type === "CNAME" || r.type === "ALIAS" ? r.content === anchor : r.content === publicIp),
        )
      ) {
        ok++;
      } else {
        conflicts++;
        console.log(`  ! ${domain.padEnd(34)} exists but points elsewhere: ${existing.map((r) => `${r.type}→${r.content}`).join(", ")} — NOT touching it`);
      }
    }
  }

  console.log(`\n${ok} in place, ${created} ${apply ? "created" : "missing (would create)"}, ${conflicts} conflict(s) needing human review.`);
  process.exit(conflicts ? 1 : 0);
}

main().catch((error) => { console.error(error.message); process.exit(1); });
