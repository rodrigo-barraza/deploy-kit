# Edge — registry-driven reverse proxy (Caddy)

Replaces hand-maintained DSM reverse-proxy rules with a Caddy container whose
config is **generated from `vault-service/projects.json`** (every project with
`visibility: "external"` + `domain`). WebSocket upgrades pass through natively —
the DSM checkbox-per-rule failure class (which broke `/admin/chat` live
streaming for weeks) cannot occur here.

**Status: groundwork.** `edge.config.json` ships with `enabled: false`;
`deploy-edge.sh` refuses to run until it's flipped. Generation, preflight, and
DNS dry-runs all work without deploying anything.

## Settings — projects.json is the source of truth

Settings resolve in two layers via `edge-config.js`:

1. `edge/edge.config.json` — committed **defaults / template** (shareable;
   what someone cloning these repos starts from).
2. `vault-service/projects.json → "edge": { ... }` — **your** values; any key
   here overrides the default and wins everywhere (all scripts read through
   the loader). No registry present → defaults alone apply.

Example (current live state — DSM is still the proxy today):

```jsonc
// projects.json
"edge": {
  "proxyMode": "dsm",
  "publicIp": "216.19.178.138",          // static IP declared; "auto" = dynamic
  "zoneProviders": { "clankerbox.com": "cloudflare" }
}
```

At cutover, the registry flips to `{ "proxyMode": "caddy", "enabled": true,
"tlsMode": "auto" }` — the committed defaults never need editing.

## Pieces

| File | Purpose |
| --- | --- |
| `edge.config.json` + `edge-config.js` | Layered settings (see above). Committed; secrets stay in env/vault. |
| `generate-caddyfile.js` | registry + config → `generated/Caddyfile` |
| `preflight.js` | Per-domain TLS + healthPath check **plus real WebSocket 101 upgrade assertions** through the proxy |
| `dns/provider.js` | Pluggable DNS provider interface + loader (secrets via env → vault) |
| `dns/porkbun.js`, `dns/cloudflare.js`, `dns/none.js` | Implementations. Add your registrar as `dns/<name>.js`; map exception zones via `zoneProviders` |
| `reconcile-dns.js` | Additive-only DNS reconciler: anchor A record + CNAMEs for every registry domain. Never edits/deletes existing records — conflicts are reported, not resolved |
| `ddns-update.js` | Cron-able: repoints ALL managed A records (anchor + foreign zones) when the public IP changes |
| `Dockerfile` / `docker-compose.yml` | Caddy built with the configured provider's DNS plugin (build arg) |
| `deploy-edge.sh` | build → ship → up → hot reload → preflight (gated on `enabled`) |

## DNS provider is a setting

`edge.config.json → dnsProvider` selects a module in `dns/`. `"porkbun"` is
implemented; `"none"` turns off all DNS automation (manage records yourself;
certs fall back to HTTP-01, which needs public port 80 → Caddy). To support
another registrar (Cloudflare, Route53, …), implement the small interface at
the top of `dns/provider.js` — including `caddyPlugin` (the `caddy-dns/*`
module to compile in) and `caddyTlsLines` (its Caddyfile `tls` stanza) — and
the generator, reconciler, DDNS, and image build all pick it up.

Porkbun secrets: `PORKBUN_API_KEY` + `PORKBUN_API_SECRET_KEY` (env or vault;
API access must also be toggled per-domain in Porkbun's dashboard). On the NAS
they go in `<composeDir>/.env` for the container.

## Commands (from deploy-kit/)

```bash
npm run edge:generate        # write generated/Caddyfile, list all routes
npm run edge:preflight       # verify domains through the proxy (health + WS upgrade)
npm run edge:dns:check       # DNS reconcile dry-run report
npm run edge:dns:apply       # create missing records (requires enabled:true)
npm run edge:deploy          # full pipeline (requires enabled:true)
```

## Keeping Synology's reverse proxy instead

Set `"proxyMode": "dsm"` — the module then never generates or deploys Caddy,
and the rest keeps working *against your DSM proxy*:

- `edge:dns:check` / `edge:dns:apply` and `ddns-update.js` — DNS automation
  is proxy-agnostic (it only needs the registry + a DNS provider).
- `edge:preflight` — connects to each domain's **public** endpoint (real DNS,
  port 443, real cert verification) and asserts health **and WebSocket
  upgrades** through whatever proxy you run. If a DSM rule is missing its
  WebSocket headers, preflight fails loudly instead of the app failing
  silently — run it after every rule you add.

You keep clicking rules into DSM by hand; the module verifies them.

## Domains at other registrars

The default provider covers most zones; exceptions go in `zoneProviders`
(registry `edge` block or defaults file):

```jsonc
"edge": { "zoneProviders": { "clankerbox.com": "cloudflare" } }
```

Reconciliation, DDNS, and DNS-01 cert challenges all use each zone's own
provider, and the Caddy image compiles every plugin the zone map needs.
Cross-zone domains get direct A records (they cannot CNAME to the anchor),
and DDNS updates ALL managed A records on an IP change — not just the
anchor. Implemented: `porkbun`, `cloudflare` (scoped token, Zone→DNS→Edit).

## Cutover runbook (when ready)

1. Vault/env: add the DNS provider keys; create `<composeDir>/.env` on the NAS.
2. `npm run edge:dns:check` → review → `npm run edge:dns:apply` (creates the
   `home.rod.dev` anchor + missing CNAMEs; touches nothing pre-existing).
3. Set `"tlsMode": "auto"` and `"enabled": true` → `npm run edge:deploy`.
   DNS-01 issues real certs **before** any public traffic reaches Caddy.
4. `npm run edge:preflight` — every domain must pass, including WS upgrades.
5. Router: forward public 80 → NAS:18080 and 443 → NAS:18443 (currently they
   point at DSM's 80/443). DSM's own rules stay untouched = instant rollback
   by reverting the router change.
6. DDNS: with `publicIp: "auto"` (dynamic IP), schedule on the NAS (Task
   Scheduler, every 5 min):
   `PROJECTS_JSON_PATH=/volume1/docker/vault-service/projects.json node /volume1/docker/edge/ddns-update.js`
   With a declared static `publicIp`, scheduling is optional insurance —
   records are enforced to the declared IP and it warns loudly if the
   egress IP ever disagrees. Either way, add an `edge-caddy` entry to the
   portal watchdog.
7. After a quiet week: delete the DSM reverse-proxy rules.

## Notes

- Certificates live in `<composeDir>/caddy-data` — persist it (it's in the
  compose volumes) or you'll re-issue on every restart and hit rate limits.
- Anything served by DSM itself that's publicly reachable needs an
  `extraSites` entry, or it goes dark at cutover — audit before step 5.
- `generated/` is git-ignored; the Caddyfile is derived state.
