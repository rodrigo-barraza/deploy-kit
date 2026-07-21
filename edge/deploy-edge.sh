#!/bin/bash
# Deploy the edge proxy to the NAS: generate Caddyfile → build image (with
# the configured DNS plugin) → ship → (re)start → hot-reload config.
#
# GATED: refuses to run while edge.config.json has enabled:false.
# Idempotent: config-only changes hot-reload with zero downtime.
set -euo pipefail

EDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${EDGE_DIR}/edge.config.json"

enabled=$(node -e "console.log(JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).enabled)")
if [ "${enabled}" != "true" ]; then
  echo "✋ edge.config.json has enabled:false — groundwork only, nothing deployed."
  echo "   Flip \"enabled\": true when ready (see edge/README.md cutover runbook)."
  exit 1
fi

read -r SSH_ALIAS COMPOSE_DIR DNS_PROVIDER < <(node -e "
const config = JSON.parse(require('fs').readFileSync('${CONFIG}','utf8'));
console.log(['nas', config.composeDir, config.dnsProvider].join(' '));
")
CADDY_PLUGIN=$(node -e "
const { loadProvider } = require('${EDGE_DIR}/dns/provider.js');
console.log(loadProvider('${DNS_PROVIDER}').caddyPlugin || '');
")

echo "→ Generating Caddyfile from registry..."
node "${EDGE_DIR}/generate-caddyfile.js"

echo "→ Building edge-caddy image (plugin: ${CADDY_PLUGIN:-none})..."
docker build --build-arg CADDY_DNS_PLUGIN="${CADDY_PLUGIN}" -t edge-caddy:latest "${EDGE_DIR}"

echo "→ Shipping to ${SSH_ALIAS}:${COMPOSE_DIR}..."
ssh "${SSH_ALIAS}" "mkdir -p '${COMPOSE_DIR}'"
docker save edge-caddy:latest | ssh "${SSH_ALIAS}" "sudo /usr/local/bin/docker load"
scp "${EDGE_DIR}/generated/Caddyfile" "${SSH_ALIAS}:${COMPOSE_DIR}/Caddyfile"
scp "${EDGE_DIR}/docker-compose.yml" "${SSH_ALIAS}:${COMPOSE_DIR}/docker-compose.yml"
scp "${EDGE_DIR}/ddns-update.js" "${SSH_ALIAS}:${COMPOSE_DIR}/ddns-update.js" 2>/dev/null || true

echo "→ Starting / reloading..."
ssh "${SSH_ALIAS}" "cd '${COMPOSE_DIR}' && sudo /usr/local/bin/docker compose up -d && sudo /usr/local/bin/docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile" \
  || { echo "compose up failed — is a .env with the DNS provider keys present in ${COMPOSE_DIR}?"; exit 1; }

echo "→ Preflight..."
node "${EDGE_DIR}/preflight.js"
