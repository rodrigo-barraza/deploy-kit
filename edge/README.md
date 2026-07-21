# Edge — registry-driven reverse proxy (Caddy)

Replaces hand-maintained DSM reverse-proxy rules with a Caddy container whose
config is **generated from `vault-service/projects.json`** (every project with
`visibility: "external"` + `domain`). WebSocket upgrades pass through natively —
the DSM checkbox-per-rule failure class (which broke `/admin/chat` live
streaming for weeks) cannot occur here.

**Status: groundwork.** `edge.config.json` ships with `enabled: false`;
`deploy-edge.sh` refuses to run until it's flipped. Generation, preflight, and
DNS dry-runs all work without deploying anything.

## Pieces

| File | Purpose |
| --- | --- |
| `edge.config.json` | Settings — DNS provider, TLS mode, ports, anchor record, extra sites. Committed; secrets stay in env/vault. |
| `generate-caddyfile.js` | registry + config → `generated/Caddyfile` |
| `preflight.js` | Per-domain TLS + healthPath check **plus real WebSocket 101 upgrade assertions** through the proxy |
| `dns/provider.js` | Pluggable DNS provider interface + loader (secrets via env → vault) |
| `dns/porkbun.js`, `dns/none.js` | Implementations. Add your registrar as `dns/<name>.js` and set `dnsProvider` |
| `reconcile-dns.js` | Additive-only DNS reconciler: anchor A record + CNAMEs for every registry domain. Never edits/deletes existing records — conflicts are reported, not resolved |
| `ddns-update.js` | Cron-able: repoints the single anchor record when the public IP changes |
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
6. Schedule `ddns-update.js` (NAS Task Scheduler, every 5 min) and add an
   `edge-caddy` entry to the portal watchdog.
7. After a quiet week: delete the DSM reverse-proxy rules.

## Notes

- Certificates live in `<composeDir>/caddy-data` — persist it (it's in the
  compose volumes) or you'll re-issue on every restart and hit rate limits.
- Anything served by DSM itself that's publicly reachable needs an
  `extraSites` entry, or it goes dark at cutover — audit before step 5.
- `generated/` is git-ignored; the Caddyfile is derived state.
