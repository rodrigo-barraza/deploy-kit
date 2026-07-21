// DNS reconciler: ensure every registry domain resolves to home.
//
// Shape: one anchor A record (config.anchorRecord → current public IP);
// subdomains in the anchor's zone are CNAME → anchor; zone apexes and
// domains in OTHER zones get direct A records. Each zone talks to its own
// DNS provider (config.zoneProviders override, else config.dnsProvider) —
// domains can live at different registrars.
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
const { providerForZone, planRecords, resolvePublicIp } = require("./dns/provider.js");

const EDGE_DIR = __dirname;
const ROOT_DIR = path.join(EDGE_DIR, "..", "..");
const registry = JSON.parse(fs.readFileSync(process.env.PROJECTS_JSON_PATH || path.join(ROOT_DIR, "vault-service", "projects.json"), "utf8"));
const config = require("./edge-config.js").loadEdgeConfig();

const apply = process.argv.includes("--apply") && config.enabled;
if (process.argv.includes("--apply") && !config.enabled) {
  console.log("⚠ edge config has enabled:false — forcing dry-run.\n");
}

async function main() {
  const anchor = config.anchorRecord;
  if (!anchor) throw new Error("edge config anchorRecord is required for DNS reconciliation");

  const domains = registry.projects
    .filter((p) => p.visibility === "external" && p.domain)
    .map((p) => p.domain)
    .concat((config.extraSites || []).map((s) => s.domain));

  const plan = planRecords(domains, anchor, config);
  const byZone = new Map();
  for (const entry of plan) {
    if (!byZone.has(entry.zone)) byZone.set(entry.zone, []);
    byZone.get(entry.zone).push(entry);
  }

  // Target IP: declared static value, or detected via the default provider.
  const { ip: publicIp, mode: ipMode } = await resolvePublicIp(
    config,
    providerForZone("", { ...config, zoneProviders: {} }),
  );
  console.log(`Public IP: ${publicIp} (${ipMode}) | anchor: ${anchor} | mode: ${apply ? "APPLY" : "dry-run"}\n`);

  let created = 0, ok = 0, conflicts = 0;

  for (const [zone, zonePlan] of byZone) {
    const provider = providerForZone(zone, config);
    let records;
    try {
      records = await provider.listRecords(zone);
    } catch (error) {
      console.log(`✘ zone ${zone} (${provider.name}): ${error.message}`);
      conflicts++;
      continue;
    }
    console.log(`zone ${zone} (${provider.name}):`);
    const findRecord = (name) =>
      records.filter((r) => r.name === name && ["A", "AAAA", "CNAME", "ALIAS"].includes(r.type));

    for (const entry of zonePlan) {
      const content = entry.contentKind === "publicIp" ? publicIp : anchor;
      const existing = findRecord(entry.name);
      if (existing.length === 0) {
        console.log(`  + ${entry.domain.padEnd(34)} ${entry.type} → ${content}${apply ? "" : "  (dry-run)"}`);
        if (apply) await provider.createRecord(zone, { name: entry.name, type: entry.type, content });
        created++;
      } else if (
        existing.some((r) =>
          (r.type === entry.type && r.content === content) ||
          (r.type === "CNAME" || r.type === "ALIAS" ? r.content === anchor : r.content === publicIp),
        )
      ) {
        ok++;
      } else {
        conflicts++;
        console.log(`  ! ${entry.domain.padEnd(34)} exists but points elsewhere: ${existing.map((r) => `${r.type}→${r.content}`).join(", ")} — NOT touching it`);
      }
    }
  }

  console.log(`\n${ok} in place, ${created} ${apply ? "created" : "missing (would create)"}, ${conflicts} conflict(s) needing human review.`);
  process.exit(conflicts ? 1 : 0);
}

main().catch((error) => { console.error(error.message); process.exit(1); });
