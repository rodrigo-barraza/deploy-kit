#!/bin/bash
# ============================================================
# Bootstrap a LAN device as a deploy-kit `docker-api` target.
#
# Installs Docker if missing (get.docker.com — supports Raspberry
# Pi OS / arm64), then exposes the Docker TCP API without TLS if
# it isn't already listening. Idempotent — safe to re-run.
#
# Usage (from the workstation):
#   ssh <user>@<host> 'sudo bash -s' < scripts/bootstrap-docker-host.sh
#
# Then register the device in vault-service/projects.json:
#   "dockerApi": "tcp://<host>:2375",
#   "deploy": { "method": "docker-api" }
#
# SECURITY: the TCP API without TLS grants root-equivalent access
# to anyone who can reach the port. Trusted home LAN only — never
# on a device exposed to the internet or a port-forwarded network.
# ============================================================
set -euo pipefail

PORT="${DOCKER_TCP_PORT:-2375}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (pipe via: ssh <user>@<host> 'sudo bash -s')" >&2
  exit 1
fi

# ── 1) Install Docker if missing ─────────────────────────────
if ! command -v docker > /dev/null 2>&1; then
  echo "- Docker not found — installing via get.docker.com..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  # Let the invoking (non-root) user run docker without sudo
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "+ Added ${SUDO_USER} to docker group (takes effect on next login)"
  fi
  echo "+ Docker installed: $(docker --version)"
else
  echo "+ Docker already installed: $(docker --version)"
fi

# ── 2) Enable plain-TCP API if not already listening ─────────
if curl -fsS --max-time 3 "http://localhost:${PORT}/_ping" > /dev/null 2>&1; then
  echo "+ Docker TCP API already enabled on :${PORT}"
else
  echo "- Enabling Docker TCP API on :${PORT} (no TLS)..."

  if grep -qs '"hosts"' /etc/docker/daemon.json 2>/dev/null; then
    echo "ERROR: /etc/docker/daemon.json already sets \"hosts\" — remove it first;" >&2
    echo "       it conflicts with the systemd -H flag and this drop-in." >&2
    exit 1
  fi

  DOCKERD_BIN="$(command -v dockerd || echo /usr/bin/dockerd)"

  # Debian's unit passes -H fd:// on the command line; a "hosts" key
  # in daemon.json conflicts with it and the daemon won't boot. The
  # systemd drop-in overriding ExecStart is the reliable path.
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/tcp-api.conf <<EOF
[Service]
ExecStart=
ExecStart=${DOCKERD_BIN} -H fd:// -H tcp://0.0.0.0:${PORT} --containerd=/run/containerd/containerd.sock
EOF
  systemctl daemon-reload
  systemctl restart docker

  sleep 2
  if curl -fsS --max-time 5 "http://localhost:${PORT}/_ping" > /dev/null 2>&1; then
    echo "+ Docker TCP API listening on :${PORT}"
  else
    echo "ERROR: TCP API still not responding — check: journalctl -u docker -n 50" >&2
    exit 1
  fi
fi

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "+ Bootstrap complete. Verify from the workstation:"
echo "    docker -H tcp://${LAN_IP:-<host>}:${PORT} info"
