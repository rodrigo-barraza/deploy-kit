# Edge proxy — Caddy with an optional DNS provider plugin compiled in.
# The plugin is a build arg so the DNS provider stays a *setting*:
#   docker build --build-arg CADDY_DNS_PLUGIN=github.com/caddy-dns/porkbun -t edge-caddy .
# (deploy-edge.sh derives the arg from edge.config.json's dnsProvider.)

ARG CADDY_VERSION=2.10

FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CADDY_DNS_PLUGIN=""
RUN if [ -n "${CADDY_DNS_PLUGIN}" ]; then \
      xcaddy build --with "${CADDY_DNS_PLUGIN}"; \
    else \
      xcaddy build; \
    fi

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
