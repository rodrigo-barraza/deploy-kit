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

The library handles validation, dependency installation, tests, image builds, transfers, and container updates. A docker CLI that dies before the daemon has started building (`cannot allocate memory` reading `~/.docker` under a parallel build load, a daemon socket that briefly refuses) is retried twice (`BUILD_CLI_RETRIES`, `BUILD_RETRY_DELAY`, `BUILD_TRANSIENT_PATTERN`); a build the daemon ran, or one that timed out, is final. The orchestrator owns scheduling, health gates, deployment state, and cleanup. A failed prerequisite or health check produces a nonzero exit; later tiers do not restart after a failed tier.

The orchestrator requires Bash 5.1+, Node.js, Git, Docker, curl, and the Linux/WSL tools `flock`, `setsid`, and `timeout`. Every run except a dry run checks that the local Docker daemon answers before it pulls or plans anything. If the daemon is down and Docker Desktop is installed (WSL), the run starts Docker Desktop and waits for it (`DOCKER_START_TIMEOUT`). If Docker Desktop is already running but its WSL integration is stopped (no `docker.sock` in the distro, as after a `wsl --shutdown` under it), the run restarts Docker Desktop instead, unless local containers are running, in which case it stops and names the fix; otherwise it stops with nothing done. SSH targets also require an SSH agent and access to their configured host. The test suite uses Python 3's standard library.

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
| `--dry-run` | Validate local files and show the plan; skip hooks, pulls, agents, builds, and remote changes |
| `--skip-pull` | Skip git pull |
| `--skip-tests` | Skip each repo's test suite — **deploys untested code** (also `SKIP_TESTS=true`) |
| `--no-cache` | Rebuild images from scratch |
| `--no-parallel` | Run build, transfer, and restart work sequentially |
| `--max-builds=N` | Maximum concurrent builds, from 1 to 64; defaults to 6, or 4 on WSL |
| `--build-only` | Build local images; no remote preparation, transfer, restart, or edge changes |
| `--changed-all` | Changed-only deployment including the temporary skip list |
| `--ignore-temp-skip` | Include temporarily excluded projects |
| `--compact-wsl` | After success, launch disk compaction in a separate elevated Windows window; WSL will shut down |
| `--changed-only` | Only build+deploy services whose source, configuration, or dependencies changed |
| `--skip-deps` | Skip library synchronization and dependency change checks |
| `--no-impact` | Disable symbol-level library impact analysis (any lib commit rebuilds all consumers) |
| `--only=a,b` | Deploy only these specific services |
| `--skip=a,b` | Skip these specific services |
| `--clients` | Deploy all `*-client` services |
| `--services` | Deploy all `*-service` services (excl. vault) |
| `--bots` | Deploy all `*-bot` services |
| `--vault` | Deploy `vault-service` only |
| `--group=x,y` | Deploy by category (`client`, `service`, `bot`, `vault`) |

## Deployment state and retries

`--changed-only` compares against the last **healthy deployment on the selected target**. Local image labels do not certify a rollout. State is written atomically under `.deploy-state/deployed/<target>/<service>.json`; build receipts live under `.deploy-state/built/<target>/<service>.json`. Receipts contain source and configuration hashes, library revisions, and image IDs; they contain no environment-file contents or secret values.

A build-only run does not advance deployment state. After a failed transfer or restart, rerunning the same deployment reuses a verified matching local image and retries the rollout. A missing/replaced local image, changed source/configuration, or `--no-cache` triggers a build. An image built with `--skip-tests` is rebuilt with tests on a later normal run before it can be reused. Changes made during a build or deployment prevent its receipt from advancing. A pending receipt forces retries after failed or interrupted mutations, even if the source is subsequently reverted; standalone deployment attempts also set this marker. Only a healthy rollout clears it.

Every service a changed-only run selects is announced with its reason: `Deploying <service> — no deployment record`, `source <old> → <new>`, `working tree changed`, `configuration changed`, `library <id> <old> → <new>`, or `an earlier rollout did not finish`. When any service has no record, one summary line says how many, because that case is easy to misread as "everything changed": a record is written only by a healthy rollout, so a run that aborts at a foundation tier leaves every service unrecorded and the next changed-only run deploys them all again.

The older `.sha` and `.deps.sha` files are not trusted as rollout receipts because they were written before deployment completed. **The first changed-only deployment after this update redeploys selected services once** to establish verified state. No manual deletion is required: each service's markers are removed when its first record is written, and a run that still finds them says so.

Unless `--skip-pull` is set, the registry and selected repositories are pulled before change detection. Repository pulls have bounded concurrency; newly discovered transitive libraries are also synchronized before planning. In changed-only mode, a registry change includes Vault before dependent deployments, even with a group or `--only` filter; explicitly skipping Vault in that situation fails. An unchanged foundation must still pass its health gate. All deployed tiers, including the last tier, are checked. HTTP checks follow the app's own redirects (up to five, so a front door that sends `/` to `/chat` is graded on `/chat`) and require a 2xx at the end of the chain; a redirect that never lands on one is not healthy.

`--skip-deps` skips shared-library synchronization and dependency change checks. A build performed this way does not certify library revisions; a later normal deployment may rebuild to verify them. `--only` bypasses the temporary skip list, while an explicit `--skip` still excludes the service. Unknown flags, groups, service IDs, and invalid concurrency values fail before deployment actions.

## Failure recovery and diagnostics

One lock covers the workspace, including linked worktrees and standalone service scripts. Each run has a separate directory under `.deploy-logs/`; dry-run diagnostics go to a temporary directory. The printed log path includes phase output and complete `<service>.docker.log` files. Existing logs are not erased at startup.

The parent collects every worker's exit code, including unexpected termination. Each build, transfer, and restart has a deadline. Cancellation terminates only process sessions created by this deployment and restores staged local environment files. Agent processes started by the script are also cleaned up.

When a service moves devices, the old container remains running during preparation. After a successful build/transfer, the script stops it, starts the replacement, and checks health. Failure restores the old container after confirming the replacement is stopped; success removes the old container and records the new target. If a device becomes unreachable during recovery, the retained container and migration log provide the recovery path; the run fails instead of reporting success.

Shared wrappers update services with `docker compose up -d --remove-orphans --no-build --pull never`, avoiding an unconditional `down`. Docker container health checks and registry HTTP checks both participate in validation. Docker runs a new container's first health probe one `interval` after start (30 s in these compose files), and the NAS's Docker 24 does not support `start_interval`. So while Docker still reports `starting`, the restart gate runs the container's own health test itself with `docker exec`. The test is the same; the gate just doesn't wait for Docker's schedule. If that test fails (the app is still booting), the gate falls back to waiting for Docker's verdict. An automatic SSH deployment cannot fall back to an uncompleted SMB export and report success. Standalone SMB export still provides manual recovery instructions and returns failure until those steps are completed.

Legacy wrappers without the shared library are validated with their dry-run mode during preparation; their full deployment runs in the restart tier. They are never passed unsupported transfer/restart-only modes, and a build-only run does not execute their remote image pulls.

## Resource limits and worktrees

Cleanup runs once locally and once per selected deployment host after workers finish. Local `:latest` and remote `:latest`/`:previous` references are retained. Build cache cleanup uses Docker's [storage retention option](https://docs.docker.com/reference/cli/docker/builder/prune/), retaining 20GB by default instead of discarding all cache. An optional minimum age further restricts which entries may be evicted; it can allow recent cache to exceed the storage target.

| Environment variable | Default | Purpose |
|---|---|---|
| `BUILD_PHASE_TIMEOUT` | `1800` | Entire service build phase, including setup and tests, in seconds |
| `BUILD_TIMEOUT` | `600` | Docker build itself, in seconds |
| `TRANSFER_PHASE_TIMEOUT` | `600` | Image transfer phase, in seconds |
| `RESTART_PHASE_TIMEOUT` | `180` | Container update phase, in seconds |
| `REMOTE_TIMEOUT` | `30` | Remote preflight, cleanup, migration, and restart-gate command timeout |
| `HEALTH_GATE_TIMEOUT` | `60` | HTTP health budget for an entire tier |
| `HEALTH_GATE_INTERVAL` | `3` | Delay between health rounds |
| `CONTAINER_HEALTH_ATTEMPTS` | `45` | Container inspect rounds after a restart; outlasts Docker's first health probe (one `interval` after start) when the container's own health test does not pass sooner |
| `CONTAINER_HEALTH_INTERVAL` | `2` | Delay between container inspect rounds |
| `MAX_CONCURRENT_SSH` | `8` | Concurrent repository pulls and transfer/restart workers |
| `DEPLOY_COMPRESSION_THREADS` | `2` | Threads per pigz compressor |
| `BUILD_CACHE_KEEP_STORAGE` | `20GB` | Cache storage to retain (`--reserved-space` on Docker 28+, `--keep-storage` before) |
| `BUILD_CACHE_MAX_AGE` | unset | Optional eviction age filter, e.g. `168h` |
| `DOCKER_START_TIMEOUT` | `120` | How long to wait for Docker Desktop after starting it |
| `DOCKER_DESKTOP_EXE` | `/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe` | Docker Desktop to start when the daemon is down |
| `DOCKER_DESKTOP_CLI` | `resources/bin/docker.exe` beside `DOCKER_DESKTOP_EXE` | Docker Desktop's Windows CLI, used to tell a stopped WSL integration from a stopped Desktop and to restart it |

A linked deploy-kit worktree uses its own code while locating sibling repositories, shared configuration, and persistent state through the primary checkout. `DEPLOY_ROOT_DIR`, `DEPLOY_CONFIG_DIR`, `DEPLOY_STATE_ROOT`, and `PROJECTS_JSON_PATH` provide explicit overrides. Existing per-service wrappers continue to work through the runner's shared-library source adapter.

`--compact-wsl` launches a detached Windows process containing the compaction commands before WSL stops. It may request Windows elevation and reports errors in its own window. Run it only when shutting down WSL is intended.

## Tests

Run `npm test` (or `python3 -m unittest discover -s tests -p test_deploy.py -v`). The suite runs the actual Bash and Node code using temporary local Git repositories and mocked Docker, SSH, DNS, HTTP, and package-manager commands. It does not contact deployment targets. Coverage includes failed prerequisites, retries, migration recovery, health gates, cancellation, locking, concurrency, library impact, worktrees, and dry runs.

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
- Debug: `node scripts/lib-impact.js --root .. --state .deploy-state/deployed \`
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

### A project inside another repository

A project is normally the workspace directory named after its registry `id`. One that lives inside a larger repository names its directory with `dir` (relative to the workspace root) and, with `sources`, the paths outside that directory its image is built from (relative to that repository's root):

```json
{ "id": "paper-tiles-service", "dir": "paper-tiles-client/rust/crates/pt-service",
  "sources": ["rust/Cargo.lock", "rust/Cargo.toml", "rust/crates/pt-server"] }
```

Its `deploy.sh` is read from `dir`. It is never pulled (the host repository moves by its own rules), and change detection fingerprints only `dir` and `sources`: the recorded sha is the last commit that touched them, so the rest of that repository moving does not redeploy it.

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

