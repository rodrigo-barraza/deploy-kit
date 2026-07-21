#!/bin/bash
# Edge config sync — regenerate the Caddyfile from the registry, ship it,
# and hot-reload the running edge-caddy. No image rebuild, no restart,
# zero-downtime; safe to run on every deploy. Silent no-op unless the edge
# is enabled and in caddy mode.
#
# Called at the end of deploy-all.sh so domain changes in projects.json
# reach the live edge automatically; also available as `npm run edge:sync`.
set -euo pipefail

EDGE_DIR="$(cd "$(dirname "$0")" && pwd)"

read -r ENABLED PROXY_MODE COMPOSE_DIR < <(node -e "
const config = require('${EDGE_DIR}/edge-config.js').loadEdgeConfig();
console.log([config.enabled, config.proxyMode || 'caddy', config.composeDir].join(' '));
")

if [ "${ENABLED}" != "true" ] || [ "${PROXY_MODE}" != "caddy" ]; then
  exit 0 # edge not managing the public surface — nothing to sync
fi

node "${EDGE_DIR}/generate-caddyfile.js" > /dev/null

# Only ship + reload when the config actually changed.
if ssh nas "cat '${COMPOSE_DIR}/Caddyfile'" 2>/dev/null | diff -q - "${EDGE_DIR}/generated/Caddyfile" > /dev/null 2>&1; then
  echo "edge: Caddyfile unchanged"
  exit 0
fi

cat "${EDGE_DIR}/generated/Caddyfile" | ssh nas "cat > '${COMPOSE_DIR}/Caddyfile'"
ssh nas "sudo /usr/local/bin/docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile"
echo "edge: Caddyfile updated + hot-reloaded"
