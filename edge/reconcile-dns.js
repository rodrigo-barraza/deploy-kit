// DNS reconciler: make DNS match the registry — create what's missing,
// remove what this tool OWNS that the registry no longer wants.
//
// Shape: one anchor A record (config.anchorRecord → public IP); subdomains
// in the anchor's zone are CNAME → anchor; zone apexes and domains in
// other zones get direct A records. Each zone talks to its own DNS
// provider (config.zoneProviders override, else config.dnsProvider).
//
// OWNERSHIP (the deletion safety model): edge/dns-ownership.json records
// every hostname this tool manages. A record is deleted ONLY when ALL of:
//   1. its hostname is in the ownership manifest,
//   2. the registry no longer wants it,
//   3. the live record still matches the managed shape (CNAME/ALIAS → the
//      anchor, or an A record at the managed public IP).
// Desired hostnames whose records pre-exist are ADOPTED into the manifest
// (they become managed from then on). Anything else — MX, TXT, SPF,
// verification records, hand-made entries pointing anywhere else — is
// invisible to deletion, forever. Manifest lost → nothing is deletable,
// and adoption rebuilds it on the next run. The manifest is LOCAL state
// (gitignored) — it describes one deployment's DNS, not the repo's.
//
// Usage:
//   node edge/reconcile-dns.js            # dry-run (always, when enabled:false)
//   node edge/reconcile-dns.js --apply    # create + prune (requires enabled:true)

const fs = require("fs");
const path = require("path");
const { providerForZone, planRecords, resolvePublicIp, zoneForDomain } = require("./dns/provider.js");

const EDGE_DIR = __dirname;
const ROOT_DIR = path.join(EDGE_DIR, "..", "..");
const MANIFEST_PATH = path.join(EDGE_DIR, "dns-ownership.json");
const registry = JSON.parse(fs.readFileSync(process.env.PROJECTS_JSON_PATH || path.join(ROOT_DIR, "vault-service", "projects.json"), "utf8"));
const config = require("./edge-config.js").loadEdgeConfig();

const apply = process.argv.includes("--apply") && config.enabled;
if (process.argv.includes("--apply") && !config.enabled) {
  console.log("⚠ edge config has enabled:false — forcing dry-run.\n");
}

function loadManifest() {
  try {
    return JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
  } catch {
    return { $comment: "Hostnames managed by edge/reconcile-dns.js — ONLY names listed here are ever deletable. Local per-deployment state (gitignored); rebuilt by adoption if lost.", records: {} };
  }
}

/** A live record "matches the managed shape" — the proof it's ours. */
function matchesManagedShape(record, anchor, publicIp) {
  if ((record.type === "CNAME" || record.type === "ALIAS") && record.content === anchor) return true;
  if (record.type === "A" && record.content === publicIp) return true;
  return false;
}

async function main() {
  const domains = registry.projects
    .filter((p) => p.visibility === "external" && p.domain)
    .map((p) => p.domain)
    .concat((config.extraSites || []).map((s) => s.domain));
  const manifest = loadManifest();

  // Nothing desired, nothing owned → nothing to reconcile. Bail before any
  // config demands so an unconfigured clone stays a quiet no-op.
  if (!domains.length && !Object.keys(manifest.records).length) {
    console.log("Registry has no external domains and the ownership manifest is empty — nothing to reconcile. (Projects with visibility:\"external\" + domain, or extraSites, opt into DNS management.)");
    return;
  }
  if (config.dnsProvider === "none" && !Object.keys(config.zoneProviders || {}).length) {
    console.log("dnsProvider is \"none\" — DNS automation is off, nothing to reconcile. Set dnsProvider (and anchorRecord) in your registry's \"edge\" block to enable it.");
    return;
  }
  // anchorRecord is optional: set → subdomains CNAME to it (one write per IP
  // change); unset → every domain gets a direct A record (DDNS rewrites each).
  const anchor = config.anchorRecord || null;

  const plan = planRecords(domains, anchor, config);
  const desiredByZone = new Map();
  for (const entry of plan) {
    if (!desiredByZone.has(entry.zone)) desiredByZone.set(entry.zone, []);
    desiredByZone.get(entry.zone).push(entry);
  }

  const desiredDomains = new Set(plan.map((e) => e.domain));

  // Zones to visit: every desired zone PLUS zones of manifest entries that
  // may need pruning (a project removed from the registry could empty a zone).
  const allZones = new Set(desiredByZone.keys());
  for (const owned of Object.keys(manifest.records)) {
    allZones.add(zoneForDomain(owned, config.zoneOverrides || {}));
  }

  const { ip: publicIp, mode: ipMode } = await resolvePublicIp(
    config,
    providerForZone("", { ...config, zoneProviders: {} }),
  );
  console.log(`Public IP: ${publicIp} (${ipMode}) | anchor: ${anchor || "none (direct A records)"} | mode: ${apply ? "APPLY" : "dry-run"}\n`);

  let created = 0, ok = 0, adopted = 0, pruned = 0, conflicts = 0;

  for (const zone of allZones) {
    const provider = providerForZone(zone, config);
    if (provider.name === "none") {
      console.log(`zone ${zone}: provider "none" — skipped (DNS automation off for this zone)`);
      continue;
    }
    let records;
    try {
      records = await provider.listRecords(zone);
    } catch (error) {
      console.log(`✘ zone ${zone} (${provider.name}): ${error.message}`);
      conflicts++;
      continue;
    }
    console.log(`zone ${zone} (${provider.name}):`);
    const routableRecords = records.filter((r) => ["A", "AAAA", "CNAME", "ALIAS"].includes(r.type));

    // ── Desired: create missing, adopt existing ──
    for (const entry of desiredByZone.get(zone) || []) {
      const content = entry.contentKind === "publicIp" ? publicIp : anchor;
      const existing = routableRecords.filter((r) => r.name === entry.name);
      if (existing.length === 0) {
        console.log(`  + ${entry.domain.padEnd(34)} ${entry.type} → ${content}${apply ? "" : "  (dry-run)"}`);
        if (apply) await provider.createRecord(zone, { name: entry.name, type: entry.type, content });
        manifest.records[entry.domain] = { type: entry.type };
        created++;
      } else if (existing.some((r) => matchesManagedShape(r, anchor, publicIp))) {
        if (!manifest.records[entry.domain]) {
          console.log(`  ⊕ ${entry.domain.padEnd(34)} adopted into ownership manifest`);
          adopted++;
        }
        manifest.records[entry.domain] = { type: existing.find((r) => matchesManagedShape(r, anchor, publicIp)).type };
        ok++;
      } else {
        conflicts++;
        console.log(`  ! ${entry.domain.padEnd(34)} exists but points elsewhere: ${existing.map((r) => `${r.type}→${r.content}`).join(", ")} — NOT touching it`);
      }
    }

    // ── Owned-but-no-longer-desired: prune (with shape proof) ──
    for (const [ownedDomain, ownedMeta] of Object.entries(manifest.records)) {
      if (desiredDomains.has(ownedDomain)) continue;
      if (zoneForDomain(ownedDomain, config.zoneOverrides || {}) !== zone) continue;
      const name = ownedDomain === zone ? "" : ownedDomain.slice(0, -(zone.length + 1));
      const target = routableRecords.find(
        (r) => r.name === name && matchesManagedShape(r, anchor, publicIp),
      );
      if (target) {
        console.log(`  − ${ownedDomain.padEnd(34)} ${target.type} → ${target.content}  (owned, no longer in registry${apply ? ", deleting" : ", dry-run"})`);
        if (apply) {
          await provider.deleteRecord(zone, target.id);
          delete manifest.records[ownedDomain];
        }
        pruned++;
      } else {
        console.log(`  ~ ${ownedDomain.padEnd(34)} owned but record changed/missing — releasing ownership, NOT deleting`);
        if (apply) delete manifest.records[ownedDomain];
        void ownedMeta;
      }
    }
  }

  if (apply) {
    fs.writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + "\n");
  }

  console.log(
    `\n${ok} in place, ${created} ${apply ? "created" : "missing (would create)"}, ` +
      `${adopted} adopted, ${pruned} ${apply ? "pruned" : "prunable"}, ${conflicts} conflict(s) needing human review.`,
  );
  process.exit(conflicts ? 1 : 0);
}

main().catch((error) => { console.error(error.message); process.exit(1); });
