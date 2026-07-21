#!/bin/bash
# Deploy the edge proxy to the NAS: generate Caddyfile → build image (with
# the configured DNS plugin) → ship → (re)start → hot-reload config.
#
# GATED: refuses to run while edge.config.json has enabled:false.
# Idempotent: config-only changes hot-reload with zero downtime.
set -euo pipefail

EDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
# Settings resolve through edge-config.js: edge.config.json defaults,
# overridden by the "edge" block in vault-service/projects.json (the SoT).

enabled=$(node -e "console.log(require('${EDGE_DIR}/edge-config.js').loadEdgeConfig().enabled)")
if [ "${enabled}" != "true" ]; then
  echo "✋ edge.config.json has enabled:false — groundwork only, nothing deployed."
  echo "   Flip \"enabled\": true when ready (see edge/README.md cutover runbook)."
  exit 1
fi

proxy_mode=$(node -e "console.log(require('${EDGE_DIR}/edge-config.js').loadEdgeConfig().proxyMode || 'caddy')")
if [ "${proxy_mode}" != "caddy" ]; then
  echo "✋ proxyMode is \"${proxy_mode}\" — this setup uses its own reverse proxy (e.g. Synology DSM)."
  echo "   Nothing to deploy. DNS automation (edge:dns:*) and verification (edge:preflight)"
  echo "   still work against your proxy."
  exit 1
fi

read -r SSH_ALIAS COMPOSE_DIR < <(node -e "
const config = require('${EDGE_DIR}/edge-config.js').loadEdgeConfig();
console.log(['nas', config.composeDir].join(' '));
")
# Union of plugins across the default provider and every zoneProviders entry.
CADDY_PLUGINS=$(node -e "
const { loadProvider } = require('${EDGE_DIR}/dns/provider.js');
const config = require('${EDGE_DIR}/edge-config.js').loadEdgeConfig();
const names = new Set([config.dnsProvider, ...Object.values(config.zoneProviders || {})]);
const plugins = new Set();
for (const name of names) {
  const plugin = loadProvider(name).caddyPlugin;
  if (plugin) plugins.add(plugin);
}
console.log([...plugins].join(' '));
")

echo "→ Generating Caddyfile from registry..."
node "${EDGE_DIR}/generate-caddyfile.js"

echo "→ Building edge-caddy image (plugins: ${CADDY_PLUGINS:-none})..."
docker build --build-arg CADDY_DNS_PLUGINS="${CADDY_PLUGINS}" -t edge-caddy:latest "${EDGE_DIR}"

echo "→ Shipping to ${SSH_ALIAS}:${COMPOSE_DIR}..."
ssh "${SSH_ALIAS}" "mkdir -p '${COMPOSE_DIR}'"
docker save edge-caddy:latest | ssh "${SSH_ALIAS}" "sudo /usr/local/bin/docker load"
scp "${EDGE_DIR}/generated/Caddyfile" "${SSH_ALIAS}:${COMPOSE_DIR}/Caddyfile"
scp "${EDGE_DIR}/docker-compose.yml" "${SSH_ALIAS}:${COMPOSE_DIR}/docker-compose.yml"
# ddns-update.js runs on the NAS via cron and needs its helpers + config.
# The NAS registry path differs, hence PROJECTS_JSON_PATH (see README).
scp -r "${EDGE_DIR}/dns" "${SSH_ALIAS}:${COMPOSE_DIR}/dns"
scp "${EDGE_DIR}/ddns-update.js" "${EDGE_DIR}/edge-config.js" "${EDGE_DIR}/edge.config.json" "${SSH_ALIAS}:${COMPOSE_DIR}/"

echo "→ Starting / reloading..."
ssh "${SSH_ALIAS}" "cd '${COMPOSE_DIR}' && sudo /usr/local/bin/docker compose up -d && sudo /usr/local/bin/docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile" \
  || { echo "compose up failed — is a .env with the DNS provider keys present in ${COMPOSE_DIR}?"; exit 1; }

echo "→ Preflight..."
node "${EDGE_DIR}/preflight.js"
