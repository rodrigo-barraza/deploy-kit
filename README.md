# Deploy Kit

Shared deployment infrastructure for all services. Contains:

- **`lib.sh`** — Shared deploy library sourced by each service's `deploy.sh`
- **`deploy-all.sh`** — Orchestrator that deploys all services in dependency order

## How It Works

Each service repo has a thin `deploy.sh` wrapper that sets its config and sources `lib.sh`:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="prism"
DISPLAY_NAME="🔷 Prism"
source "${SCRIPT_DIR}/../deploy-kit/lib.sh"
```

The library handles the full pipeline: flag parsing, git pull, Docker build, SSH transfer, container restart, image pruning, and SMB fallback.

## Usage

```bash
# Full deploy (all services)
npm run deploy

# Dry run (validate only)
npm run deploy:dry

# Deploy only changed services
npm run deploy:changed

# Deploy only changed services, skipping dependency checks
npm run deploy:changed:no-deps

# Deploy every changed project without running its tests
npm run deploy:changed-all:no-tests
```

### Group Deploy

Deploy by category — services are classified by their ID suffix (`-service`, `-client`, `-bot`):

```bash
# By category
npm run deploy:clients          # all *-client services
npm run deploy:services         # all *-service services (excludes vault)
npm run deploy:bots             # all *-bot services
npm run deploy:vault            # vault-service only

# Combine groups
npm run deploy -- --clients --bots         # clients + bots
npm run deploy -- --group=client,service   # clients + services

# Groups compose with other flags
npm run deploy:clients -- --changed-only   # only changed clients
npm run deploy:services -- --no-cache      # rebuild all service images
npm run deploy:clients -- --skip=rod-dev-client  # all clients except rod-dev
```

### Individual Deploy

```bash
# From deploy-kit/
npm run deploy:prism-service
npm run deploy:prism-client
npm run deploy:lupos-bot
# ... etc (see package.json for full list)

# Specific services via flag
npm run deploy -- --only=prism-service,prism-client

# Skip specific services
npm run deploy -- --skip=lupos-bot,lights-service
```

### Flags

| Flag | Description |
|---|---|
| `--dry-run` | Validate only, no changes |
| `--skip-pull` | Skip git pull |
| `--skip-tests` | Skip each repo's test suite — **deploys untested code** (also `SKIP_TESTS=true`) |
| `--no-cache` | Rebuild images from scratch |
| `--no-parallel` | Disable parallel builds |
| `--changed-only` | Only build+deploy services with git changes |
| `--skip-deps` | Skip library build and dependency change checks |
| `--no-impact` | Disable symbol-level library impact analysis (any lib commit rebuilds all consumers) |
| `--only=a,b` | Deploy only these specific services |
| `--skip=a,b` | Skip these specific services |
| `--clients` | Deploy all `*-client` services |
| `--services` | Deploy all `*-service` services (excl. vault) |
| `--bots` | Deploy all `*-bot` services |
| `--vault` | Deploy `vault-service` only |
| `--group=x,y` | Deploy by category (`client`, `service`, `bot`, `vault`) |

## Library Impact Analysis

In `--changed-only` mode, a library commit no longer rebuilds every
consumer. `scripts/lib-impact.js` maps each library's changed files
through its internal import graph to the exact export surface that
changed (subpath exports, barrel symbols, css), then intersects that
with what each service actually imports (src + next.config/*.config
files). Only services whose imports are touched rebuild.

- **Cross-library propagation**: if utilities-library changes a symbol
  that components-library uses inside e.g. `ChatComponent`, clients
  importing `ChatComponent` are affected even without importing the
  utilities symbol directly.
- **Barrel edits are diffed old-vs-new**: newly *added* exports rebuild
  nobody; removed/remapped exports rebuild their importers.
- **Fail-open**: `package.json` changes, deleted src files, dist drift
  without src changes, unparseable imports, or any script failure all
  degrade to "rebuild everyone" — never a silent skip.
- **Per-project override**: `"libImpact": "all"` in projects.json forces
  a project to rebuild on any library change (portal-client uses this —
  its prebuild codegen catalogs the whole library surface).
- Skipped services log the reason:
  `Skipping rod-dev-client — components-library: 2 files (InputComponent.tsx, …) — not imported`.
- Debug: `node scripts/lib-impact.js --root .. --state .deploy-state \`
  `--projects ../vault-service/projects.json --pairs "svc:lib,..." --human`
  (add `--override-base <lib>=<sha>` to simulate a base).

## Hook Points

Services with special needs define functions before sourcing:

| Hook | Purpose | Used by |
|---|---|---|
| `EXTRA_VALIDATE()` | Additional file checks | vault |
| `PRE_BUILD()` | Set `BUILD_ARGS` before Docker build | portal, prism-client, rod-dev |
| `EXTRA_SSH_SYNC()` | Sync extra files during SSH deploy | vault, rod-dev |
| `EXTRA_SMB_SYNC()` | Sync extra files during SMB fallback | vault |

## Hand steps the kit does not do

The registry has one `port` per project and the edge generator emits HTTP
only, so anything that is not an HTTP port is a hand step on the router —
recorded here so a fresh NAS or a replaced router does not silently lose it.

| Service | Step | Proof |
|---|---|---|
| `games-service` | Forward **UDP 5611** from the router to the NAS — the proximity-voice relay and the presence datagrams that ride it (`docker-compose.yml` publishes `5611:5611/udp`; Caddy carries none of it). Missing, every player on a shared ranch sees 📵. | In `games-service`: `node tests/live/relay-echo.mjs https://api.games.rod.dev` — its README → Deploying |

## Config Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `IMAGE_NAME` | ✅ | — | Docker image name |
| `DISPLAY_NAME` | ❌ | `IMAGE_NAME` | Header label with emoji |
| `BUILD_ARGS` | ❌ | `""` | Extra `--build-arg` flags |
| `BUILD_EXTRA_FLAGS` | ❌ | `""` | Extra Docker build flags (e.g. `--network=host`) |
| `BUILD_TAIL_LINES` | ❌ | `5` | Lines of build output to show |
| `SKIP_ENV_DEPLOY` | ❌ | `false` | Skip `.env.deploy` validation |

## Multi-Device Deployment

Services can deploy to different devices. Configuration lives in `vault-service/projects.json` (single source of truth).

### How It Works

Each project can specify a `deployTarget` device ID (defaults to `"synology"`):

```json
{
  "id": "reels-service",
  "deployTarget": "workstation2"
}
```

Each device in the `devices` array declares its deploy method:

```json
{
  "id": "workstation2",
  "dockerApi": "tcp://192.168.86.178:2375",
  "deploy": { "method": "docker-api" }
}
```

```json
{
  "id": "synology",
  "sshAlias": "nas",
  "deploy": {
    "method": "ssh",
    "composeRoot": "/volume1/docker",
    "smbRoot": "/mnt/k"
  }
}
```

### Deploy Methods

| Method | How | Used For |
|---|---|---|
| `ssh` | Pipe image over SSH, copy compose + env, restart remotely | Synology NAS (default) |
| `docker-api` | Pipe image via `docker -H`, run compose locally with `DOCKER_HOST` | Windows machines with Docker Desktop |

### Compose Override Files

Services with device-specific config (e.g. volume paths) use compose file stacking. Place a `docker-compose.{deviceId}.yml` in the service directory:

```yaml
# reels-service/docker-compose.workstation2.yml
services:
  reels-service:
    user: ""
    volumes:
      - D:/media:/media:ro
```

This is automatically detected and stacked on top of the base `docker-compose.yml` during deploy.

### Adding a New Device Target

1. Add the device to `projects.json` → `devices[]` with a `deploy` config
2. Set `deployTarget` on any project that should deploy there
3. Optionally create `docker-compose.{deviceId}.yml` overrides in service directories

---

## Setting Up Docker TCP API on Windows

Required for any Windows machine used as a `docker-api` deploy target.

### 1. Enable TCP in Docker Desktop

**Docker Desktop → Settings → General → ✅ "Expose daemon on tcp://localhost:2375 without TLS"**

> ⚠️ **Do NOT** set `hosts` in `daemon.json` — Docker Desktop passes its own `-H` flag internally, which conflicts and prevents the engine from starting.

Verify it works locally:

```powershell
docker -H tcp://127.0.0.1:2375 version
```

### 2. Expose on LAN via Port Proxy

Docker Desktop only binds to `localhost`. Use `netsh portproxy` to forward the LAN IP to localhost (PowerShell as Admin):

```powershell
netsh interface portproxy add v4tov4 listenport=2375 listenaddress=<LAN_IP> connectport=2375 connectaddress=127.0.0.1
```

> ⚠️ **Use the specific LAN IP**, not `0.0.0.0`. Binding to all interfaces steals the port from Docker Desktop's own `127.0.0.1` listener.

### 3. Allow Through Firewall

```powershell
New-NetFirewallRule -DisplayName "Docker TCP API" -Direction Inbound -Protocol TCP -LocalPort 2375 -Action Allow
```

### 4. Restart IP Helper

The `netsh portproxy` relay depends on the IP Helper service:

```powershell
Restart-Service iphlpsvc
```

### 5. Verify Cross-Machine

From any other machine on the LAN:

```bash
docker -H tcp://<LAN_IP>:2375 version
```

Both Client and Server sections should appear. API version auto-negotiation (`downgraded from X.XX`) is normal and harmless.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Docker Engine stopped` | `hosts` in `daemon.json` | Remove `hosts`, use Docker Desktop TCP checkbox instead |
| `EOF` on connect | Port proxy on `0.0.0.0` stealing the port | Rebind to specific LAN IP |
| `Cannot connect` after adding proxy | IP Helper not restarted | `Restart-Service iphlpsvc` |
| API version mismatch warning | Different Docker versions | Normal — auto-negotiated, no action needed |

## Scripts

```bash
npm run deploy           # Deploy all services in dependency order
npm run deploy:dry       # Validate all deployments without deploying
npm run cleanup          # Clean up local Docker images
npm run cleanup:force    # Force clean up local Docker images
npm run deploy:bots      # Deploy all bot services
npm run deploy:changed   # Deploy only services with git changes
npm run deploy:changed:no-deps # Deploy changed services, skipping library sync and dependency change checks
npm run deploy:clients   # Deploy all client applications
npm run deploy:services  # Deploy all backend services (excl. vault)
npm run deploy:sync      # Sync deploy.sh scripts across projects
npm run deploy:vault     # Deploy vault-service only
```

### Per-Service Deploy

```bash
# Individual services (see package.json for full list)
npm run deploy:clankerbox-client
npm run deploy:clankerbox-service
npm run deploy:classic-whitemane-client
npm run deploy:clock-crew-client
npm run deploy:clock-crew-service
# ... and 25 more
```

