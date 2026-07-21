# Edge proxy — Caddy with the needed DNS provider plugin(s) compiled in.
# Plugins are a build arg (space-separated) so DNS providers stay *settings*:
#   docker build --build-arg CADDY_DNS_PLUGINS="github.com/caddy-dns/porkbun github.com/caddy-dns/cloudflare" -t edge-caddy .
# (deploy-edge.sh derives the list from the default provider + zoneProviders.)

ARG CADDY_VERSION=2.10

FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CADDY_DNS_PLUGINS=""
RUN set -e; \
    args=""; \
    for plugin in ${CADDY_DNS_PLUGINS}; do args="${args} --with ${plugin}"; done; \
    xcaddy build ${args}

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
