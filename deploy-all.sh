#!/bin/bash
# ============================================================
# Deploy All Services
#
# Three-phase pipeline:
#   Phase 1 — BUILD + TRANSFER: all services build in parallel.
#             As each build completes, its image transfer to the
#             target device starts immediately (pipeline parallelism).
#             Total time ≈ slowest build + its transfer.
#   Phase 2 — RESTART: tier-by-tier in dependency order.
#             Each tier waits for its transfers to finish,
#             restarts containers, then health-gates before
#             proceeding to the next tier.
#
# Tiers are auto-derived from vault-service/projects.json:
#   0. Foundation   — secret store (must be up first)
#   1. APIs/Clients — backend services and frontends
#   2. Bots         — discord bots and background workers
#
# Usage:
#   npm run deploy                         # full deploy
#   npm run deploy -- --dry-run            # validate only
#   npm run deploy -- --skip-pull          # skip git pull
#   npm run deploy -- --no-cache           # rebuild images from scratch
#   npm run deploy -- --changed-only       # only build+deploy services with git changes
#   npm run deploy -- --changed-all        # changed services, ignoring the TEMPORARY_SKIP list
#   npm run deploy -- --ignore-temp-skip   # disable the TEMPORARY_SKIP list for this run
#   npm run deploy -- --skip-deps          # skip library build and dependency change checks
#   npm run deploy -- --no-impact          # disable symbol-level library impact analysis
#                                            (fall back to "any lib commit rebuilds all consumers")
#   npm run deploy -- --build-only         # build Docker images only (no transfer/restart)
#   npm run deploy -- --only=prism-service,prism-client  # deploy specific services
#   npm run deploy -- --skip=lupos-bot,lights-service  # skip specific services
#   npm run deploy -- --no-parallel        # disable parallel builds
#   npm run deploy -- --max-builds=6       # max concurrent docker builds (default: 6, or 4 on WSL2)
#   npm run deploy -- --compact-wsl        # compact WSL2 VHDX after pruning (reclaim Windows disk)
#
# Group deploy (by category):
#   npm run deploy -- --clients            # deploy all *-client services
#   npm run deploy -- --services           # deploy all *-service services (excl. vault)
#   npm run deploy -- --bots               # deploy all *-bot services
#   npm run deploy -- --vault              # deploy vault-service only
#   npm run deploy -- --group=client,bot   # deploy clients + bots
# ============================================================

set -euo pipefail

# Clean up semaphore FIFO and play completion earcons (auditory notifications) on exit
MAIN_PID=$BASHPID
cleanup() {
  # Capture exit code IMMEDIATELY — before any conditional clobbers $?
  local exit_code=$?

  # Only execute in the main script process to avoid subshell duplicate notifications
  if [ "${BASHPID:-}" = "${MAIN_PID:-}" ]; then
    
    # Close semaphore file descriptors
    exec 7>&- 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    
    # Clean up FIFOs, health files, and PIDs
    rm -f "${LOG_DIR:-.deploy-logs}/.build-semaphore" 2>/dev/null || true
    rm -f "${LOG_DIR:-.deploy-logs}/.ssh-semaphore" 2>/dev/null || true
    rm -rf "${LOG_DIR:-.deploy-logs}"/.health-* 2>/dev/null || true
    rm -f "${LOG_DIR:-.deploy-logs}"/*.pid 2>/dev/null || true


    # Play completion sound if not in a dry-run (and not user-cancelled)
    if [ "${DRY_RUN:-false}" = "false" ] && [ "${INTERRUPTED:-false}" = "false" ]; then
      local has_unhealthy=false
      if ls "${LOG_DIR:-.deploy-logs}"/*.health.status >/dev/null 2>&1; then
        if grep -q "UNHEALTHY" "${LOG_DIR:-.deploy-logs}"/*.health.status 2>/dev/null; then
          has_unhealthy=true
        fi
      fi

      if [ "$exit_code" -eq 0 ] && [ "$has_unhealthy" = "false" ]; then
        # Succeeded: play Tada chime
        if command -v powershell.exe >/dev/null 2>&1; then
          powershell.exe -Command "(New-Object Media.SoundPlayer 'C:\Windows\Media\tada.wav').PlaySync()" >/dev/null 2>&1 || true
        fi
      else
        # Failed or Unhealthy: play Uh-Oh sound if available, otherwise Chord warning
        local sound_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
        local uhoh_wav="${sound_dir}/uhoh.wav"
        if [ -f "$uhoh_wav" ] && command -v powershell.exe >/dev/null 2>&1; then
          local win_path
          win_path=$(wslpath -w "$uhoh_wav" 2>/dev/null || echo "")
          if [ -n "$win_path" ]; then
            powershell.exe -Command "(New-Object Media.SoundPlayer '$win_path').PlaySync()" >/dev/null 2>&1 || true
          else
            powershell.exe -Command "(New-Object Media.SoundPlayer 'C:\Windows\Media\chord.wav').PlaySync()" >/dev/null 2>&1 || true
          fi
        elif command -v powershell.exe >/dev/null 2>&1; then
          powershell.exe -Command "(New-Object Media.SoundPlayer 'C:\Windows\Media\chord.wav').PlaySync()" >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi
}
trap cleanup EXIT

# ── Interrupt handling (Ctrl+C) ───────────────────────────────
# Jobs launched with & in a non-interactive shell start with SIGINT
# ignored (POSIX), so Ctrl+C kills only this main process and orphans
# every build/transfer job — and their docker/pnpm children keep
# running and printing to the terminal. SIGTERM is NOT ignored, so on
# interrupt we TERM the entire process group to stop the pipeline.
INTERRUPTED=false
on_interrupt() {
  trap '' INT TERM   # shield ourselves from the group-wide TERM below
  INTERRUPTED=true
  printf '\n  Interrupted — stopping all build/transfer jobs...\n' >&2
  kill -TERM 0 2>/dev/null || true
  wait 2>/dev/null || true
  exit 130
}
trap on_interrupt INT TERM


# ── Config ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # sun/ parent directory
LOG_DIR="${SCRIPT_DIR}/.deploy-logs"
PROJECTS_JSON="${ROOT_DIR}/vault-service/projects.json"

# ── SSH agent (for BuildKit --ssh default in docker build) ────
# Child deploy.sh processes need SSH_AUTH_SOCK to forward the
# agent into RUN --mount=type=ssh layers for private git deps.
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  ssh_status=0
  ssh-add -l >/dev/null 2>&1 || ssh_status=$?
  if [ $ssh_status -eq 2 ]; then
    unset SSH_AUTH_SOCK
  fi
fi

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  eval "$(ssh-agent -s)" > /dev/null 2>&1
  export SSH_AUTH_SOCK SSH_AGENT_PID
fi
if ! ssh-add -l > /dev/null 2>&1; then
  ssh-add 2> /dev/null || true
fi

# ── Verify projects.json ──────────────────────────────────────
if [ ! -f "$PROJECTS_JSON" ]; then
  echo "ERROR: projects.json not found at ${PROJECTS_JSON}" >&2
  exit 1
fi

# ── Dynamically load tiers from projects.json ─────────────────
# Uses Node.js (always available) to parse JSON and emit bash-eval
# assignments: MAX_TIER, TIER_SERVICES[n], TIER_<n> arrays,
# and SVC_HEALTH_URL[id] for health-gating between tiers.
ALL_SERVICES=()
declare -A TIER_SERVICES  # tier -> space-separated service IDs
declare -A SVC_HEALTH_URL # service-id -> health check URL
declare -A SVC_DEPLOY_TARGET  # service-id -> device ID
declare -A SVC_LIB_DEPS   # service-id -> space-separated library dependency IDs
declare -A SVC_DEPS       # service-id -> space-separated all dependency IDs

# Device metadata (populated from projects.json devices array)
declare -A DEVICE_METHOD      # device-id -> ssh | docker-api
declare -A DEVICE_HOSTNAME    # device-id -> IP/hostname
declare -A DEVICE_SSH_ALIAS   # device-id -> SSH config alias
declare -A DEVICE_DOCKER_BIN  # device-id -> path to docker binary
declare -A DEVICE_DOCKER_API  # device-id -> tcp://host:port
declare -A DEVICE_COMPOSE_ROOT # device-id -> remote compose dir root
declare -A DEVICE_SMB_ROOT    # device-id -> SMB mount path

eval "$(node "${SCRIPT_DIR}/scripts/parse-projects.js" "$PROJECTS_JSON" "$ROOT_DIR")"

# Iterate tiers numerically — assoc-array key order is arbitrary,
# and ALL_SERVICES ordering drives summary/log output.
for s in $(seq 0 "$MAX_TIER"); do
  for id in ${TIER_SERVICES[$s]:-}; do
    ALL_SERVICES+=("$id")
  done
done

# ── Colors & logging (shared) ─────────────────────────────────
source "${SCRIPT_DIR}/colors.sh"

# ── Box & rule helpers ────────────────────────────────────────
# Padding is computed from character counts, so multibyte glyphs
# (em dashes) no longer skew the right border.
BOX_WIDTH=58
box() {
  local color="$1"; shift
  local border line pad
  printf -v border '%*s' "$BOX_WIDTH" ''
  border=${border// /─}
  printf '\n%s%s┌%s┐%s\n' "$color" "$BOLD" "$border" "$RESET"
  for line in "$@"; do
    pad=$(( BOX_WIDTH - 2 - ${#line} ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%s│  %s%*s│%s\n' "$color" "$BOLD" "$line" "$pad" '' "$RESET"
  done
  printf '%s%s└%s┘%s\n' "$color" "$BOLD" "$border" "$RESET"
}

rule() {
  local color="${1:-$MAGENTA}" border
  printf -v border '%*s' 62 ''
  border=${border// /═}
  printf '%s%s%s%s\n' "$color" "$BOLD" "$border" "$RESET"
}

# ── Inline progress percentage ────────────────────────────────
# Counts completed phase status files against a precomputed total
# (PROGRESS_TOTAL, set after flag parsing). Sets PROGRESS_PCT to a
# zero-padded string like "025%". Pure builtins — this runs once per
# log line, so no forks and no per-service filter checks allowed here.
PROGRESS_TOTAL=0
progress_percentage() {
  local completed=0 f
  for f in "${LOG_DIR}"/*.build.status "${LOG_DIR}"/*.transfer.status "${LOG_DIR}"/*.deploy.status; do
    [ -e "$f" ] && completed=$((completed + 1))
  done
  local percentage=0
  [ "$PROGRESS_TOTAL" -gt 0 ] && percentage=$(( completed * 100 / PROGRESS_TOTAL ))
  [ "$percentage" -gt 100 ] && percentage=100
  printf -v PROGRESS_PCT '%03d%%' "$percentage"
}

# Override ts() to prepend elapsed seconds and progress percentage before
# the timestamp. Uses printf's %()T builtin instead of $(date) — no fork.
ts() {
  progress_percentage
  printf '%s%04ds %s %(%H:%M:%S)T%s' "$DIM" "$(( SECONDS - ${DEPLOY_START:-$SECONDS} ))" "$PROGRESS_PCT" -1 "$RESET"
}


# ── Service colors (semantic per-category shades) ────────────
# Services=blue, Clients=green, Bots=yellow. Red is errors only.
# Shades rotate within each category for visual differentiation.
declare -A SVC_COLORS
for svc in "${ALL_SERVICES[@]}"; do
  SVC_COLORS[$svc]=$(svc_color "$svc")
done

# ── Flags ─────────────────────────────────────────────────────
DRY_RUN=false
ANY_LIB_CHANGED=false
export ANY_LIB_CHANGED
SKIP_PULL=false
IGNORE_TEMP_SKIP=false
NO_CACHE=false
NO_PARALLEL=false
ONLY=""
SKIP_LIST=""
CHANGED_ONLY=false
SKIP_DEPS=false
NO_IMPACT=false
BUILD_ONLY=false
COMPACT_WSL=false
GROUP=""
MAX_CONCURRENT_BUILDS=6   # Limit concurrent docker builds to prevent CPU/IO and disk saturation
# Detect WSL2 and automatically reduce builds to prevent CPU/IO starvation
if grep -qi microsoft /proc/version 2>/dev/null; then
  MAX_CONCURRENT_BUILDS=4
fi
export MAX_CONCURRENT_BUILDS
MAX_CONCURRENT_SSH=8      # Subject to the target SSH server's MaxSessions limit (default: 10) even when multiplexed

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --skip-pull)      SKIP_PULL=true ;;
    --no-cache)       NO_CACHE=true ;;
    --no-parallel)    NO_PARALLEL=true ;;
    --changed-only)   CHANGED_ONLY=true ;;
    --ignore-temp-skip) IGNORE_TEMP_SKIP=true ;;
    --changed-all)    CHANGED_ONLY=true; IGNORE_TEMP_SKIP=true ;;
    --skip-deps)      SKIP_DEPS=true ;;
    --no-impact)      NO_IMPACT=true ;;
    --build-only)     BUILD_ONLY=true ;;
    --compact-wsl)    COMPACT_WSL=true ;;
    --only=*)         ONLY="${arg#--only=}" ;;
    --skip=*)         SKIP_LIST="${arg#--skip=}" ;;
    --group=*)        GROUP="${arg#--group=}" ;;
    --clients)        GROUP="${GROUP:+${GROUP},}client" ;;
    --services)       GROUP="${GROUP:+${GROUP},}service" ;;
    --bots)           GROUP="${GROUP:+${GROUP},}bot" ;;
    --vault)          GROUP="${GROUP:+${GROUP},}vault" ;;
    --max-builds=*)   MAX_CONCURRENT_BUILDS="${arg#--max-builds=}" ;;

  esac
done

# ── TEMPORARY SKIP LIST (remove when these projects are ready) ─
# These projects are temporarily excluded from full deploys.
# To deploy them individually, use: npm run deploy -- --only=<service-id>
# To deploy everything that changed regardless of this list, use:
#   npm run deploy:changed-all   (or pass --ignore-temp-skip)
TEMPORARY_SKIP="qbittorent-service,accounts-service,accounts-client,animals-service,animals-client,clankerbox-service,clankerbox-client,clock-crew-service,clock-crew-client,classic-whitemane-client,dygest-service,dygest-client,games-service,games-client,gauge-service,gauge-client,images-service,images-client,iron-service,iron-client,ledger-service,ledger-client,lights-client,lupos-client,meepothegeomancer-client,messages-service,messages-client,music-service,music-client,notes-service,notes-client,reels-service,reels-client,payments-service,payments-client"
if [ "${IGNORE_TEMP_SKIP:-false}" != "true" ]; then
  if [ -n "$SKIP_LIST" ]; then
    SKIP_LIST="${SKIP_LIST},${TEMPORARY_SKIP}"
  else
    SKIP_LIST="$TEMPORARY_SKIP"
  fi
fi

# ── Prefetch git.sha image labels (one docker call, not N) ────
# has_changes() needs the git.sha label of every <svc>:latest image.
# Inspecting them one-by-one costs ~100ms per docker CLI invocation;
# a single batched inspect fetches them all at once.
declare -A IMAGE_SHA
if $CHANGED_ONLY; then
  _images=()
  for svc in "${ALL_SERVICES[@]}"; do _images+=("${svc}:latest"); done
  while IFS='|' read -r _tags _sha; do
    [ "$_sha" = "<no value>" ] && _sha=""
    for _tag in ${_tags//,/ }; do
      case "$_tag" in
        *:latest) IMAGE_SHA[${_tag%:latest}]="$_sha" ;;
      esac
    done
  done < <(docker image inspect --format '{{join .RepoTags ","}}|{{index .Config.Labels "git.sha"}}' "${_images[@]}" 2>/dev/null || true)
fi

# ── Detect projects.json changes (force vault-service deploy) ─
# When --changed-only is set, check if vault-service/projects.json
# was modified since the last vault-service image was built. If so,
# vault-service MUST be redeployed before any other service so that
# dependents pick up the latest config registry.
VAULT_CONFIG_CHANGED=false
if $CHANGED_ONLY; then
  _vault_last_sha="${IMAGE_SHA[vault-service]:-}"
  if [ -n "$_vault_last_sha" ]; then
    if ! (cd "${ROOT_DIR}/vault-service" && git diff --quiet "$_vault_last_sha" HEAD -- projects.json 2>/dev/null); then
      VAULT_CONFIG_CHANGED=true
    fi
  else
    # No previous vault image — treat config as changed
    VAULT_CONFIG_CHANGED=true
  fi
fi

# ── Service filter ────────────────────────────────────────────
should_deploy() {
  local svc="$1"

  # --group filter: if set, service must match one of the categories
  # Categories: "service", "client", "bot", "vault" (vault-service specifically)
  if [ -n "$GROUP" ]; then
    local svc_cat
    svc_cat=$(svc_category "$svc")
    local match=false
    IFS=',' read -ra groups <<< "$GROUP"
    for g in "${groups[@]}"; do
      case "$g" in
        vault)   [ "$svc" = "vault-service" ] && match=true ;;
        service) [ "$svc_cat" = "service" ] && [ "$svc" != "vault-service" ] && match=true ;;
        *)       [ "$svc_cat" = "$g" ] && match=true ;;
      esac
    done
    $match || return 1
  fi

  # --only filter: if set, service must be in the list
  if [ -n "$ONLY" ]; then
    [[ ",$ONLY," == *",$svc,"* ]] && return 0 || return 1
  fi

  # --skip filter: if set, service must NOT be in the list
  if [ -n "$SKIP_LIST" ]; then
    [[ ",$SKIP_LIST," == *",$svc,"* ]] && return 1 || return 0
  fi

  return 0
}

# ── Cache should_deploy verdicts ──────────────────────────────
# Filters are fixed once flags are parsed, so evaluate each service
# once and turn should_deploy into a pure array lookup (it's called
# from hot paths and background jobs).
declare -A SVC_DEPLOYABLE
for svc in "${ALL_SERVICES[@]}"; do
  if should_deploy "$svc"; then SVC_DEPLOYABLE[$svc]=1; else SVC_DEPLOYABLE[$svc]=0; fi
done
should_deploy() { [ "${SVC_DEPLOYABLE[$1]:-0}" = "1" ]; }

# ── Progress denominator ──────────────────────────────────────
# One build unit per service, plus (unless --build-only) one deploy
# unit per service and one transfer unit per deployable service in
# parallel mode. Matches the status files progress_percentage counts.
for svc in "${ALL_SERVICES[@]}"; do
  PROGRESS_TOTAL=$((PROGRESS_TOTAL + 1))
  if ! $BUILD_ONLY; then
    PROGRESS_TOTAL=$((PROGRESS_TOTAL + 1))
    if ! $NO_PARALLEL && should_deploy "$svc"; then
      PROGRESS_TOTAL=$((PROGRESS_TOTAL + 1))
    fi
  fi
done

# ── Persistent deploy-state directory (survives across runs) ──
DEPLOY_STATE_DIR="${SCRIPT_DIR}/.deploy-state"
mkdir -p "$DEPLOY_STATE_DIR"

# ── Change detection ──────────────────────────────────────────
# Returns 0 (true) if service has changes since last built image.
# Two-tier SHA lookup:
#   1. Docker image label "git.sha" (services that build locally)
#   2. Persistent marker file .deploy-state/<svc>.sha (services
#      using pre-built images, e.g. qbittorrent-service)
has_changes() {
  local svc="$1"
  local svc_dir="${ROOT_DIR}/${svc}"

  # If --changed-only is not set, always consider changed
  if ! $CHANGED_ONLY; then
    return 0
  fi

  # Force vault-service when projects.json changed — the config
  # registry must be live before any dependent services start.
  if [ "$svc" = "vault-service" ] && $VAULT_CONFIG_CHANGED; then
    return 0
  fi

  # Tier 1: Docker image label (batch-prefetched into IMAGE_SHA at startup)
  local last_sha="${IMAGE_SHA[$svc]:-}"

  # Tier 2: Persistent marker file (pre-built / non-docker-build services)
  if [ -z "$last_sha" ]; then
    local marker_file="${DEPLOY_STATE_DIR}/${svc}.sha"
    if [ -f "$marker_file" ]; then
      last_sha=$(cat "$marker_file" 2>/dev/null || echo "")
    fi
  fi

  if [ -z "$last_sha" ]; then
    # No previous image or marker — must build
    return 0
  fi

  # Check if there are any changes since that SHA in the service itself
  if ! (cd "$svc_dir" && git diff --quiet "$last_sha" -- . 2>/dev/null) || \
     [ -n "$(cd "$svc_dir" && git ls-files --others --exclude-standard . 2>/dev/null)" ]; then
    # Has changes
    return 0
  fi

  # Check if any library dependency has changed since the last deploy of this service
  if ! $SKIP_DEPS && [ -n "${SVC_LIB_DEPS[$svc]:-}" ]; then
    local dep_file="${DEPLOY_STATE_DIR}/${svc}.deps.sha"
    if [ ! -f "$dep_file" ]; then
      # Quietly initialize the dependency marker file to prevent false-positive initial bootstrap builds
      rm -f "$dep_file"
      for dep_id in ${SVC_LIB_DEPS[$svc]}; do
        local dep_dir="${ROOT_DIR}/${dep_id}"
        local dep_sha
        dep_sha=$(cd "$dep_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$dep_sha" ]; then
          echo "${dep_id}: ${dep_sha}" >> "$dep_file"
        fi
      done
    fi

    # ── Symbol-level impact verdict (scripts/lib-impact.js) ────
    # When the analysis ran successfully, its verdict replaces the
    # coarse SHA comparison below: a library change only triggers a
    # rebuild when this service actually imports an affected export
    # (directly, or through components-library's use of utilities).
    # All analysis uncertainty resolves to "affected" inside the
    # script (fail-open); a script failure leaves IMPACT_SCRIPT_OK
    # false so we fall through to the legacy whole-library check.
    if [ "${IMPACT_SCRIPT_OK:-false}" = "true" ] && [ -n "${IMPACT_VERDICT[$svc]:-}" ]; then
      if [ "${IMPACT_VERDICT[$svc]}" = "affected" ]; then
        return 0
      fi
      return 1   # unaffected | none — no library-triggered rebuild
    fi

    # Read the saved dependency SHAs
    declare -A saved_shas
    while IFS=': ' read -r dep_id dep_sha || [ -n "$dep_id" ]; do
      [ -z "$dep_id" ] && continue
      saved_shas[$dep_id]="$dep_sha"
    done < "$dep_file"

    for dep_id in ${SVC_LIB_DEPS[$svc]}; do
      local dep_dir="${ROOT_DIR}/${dep_id}"
      # Stale or phantom dependency (e.g. the merged-away
      # service-library): a missing directory yields no signal, but
      # the cd-failure below would read as "dirty" and force a
      # rebuild on every single run.
      [ -d "$dep_dir" ] || continue
      local current_dep_sha
      current_dep_sha=$(cd "$dep_dir" && git rev-parse HEAD 2>/dev/null || echo "")
      local saved_dep_sha="${saved_shas[$dep_id]:-}"

      if [ "$current_dep_sha" != "$saved_dep_sha" ]; then
        # Library SHA has changed!
        return 0
      fi

      # Also check if the library directory itself has dirty uncommitted changes or unpushed commits
      if ! (cd "$dep_dir" && git diff --quiet HEAD -- . 2>/dev/null) || \
         [ -n "$(cd "$dep_dir" && git ls-files --others --exclude-standard . 2>/dev/null)" ]; then
        # Library has local uncommitted changes!
        return 0
      fi
      if (cd "$dep_dir" && git rev-parse --abbrev-ref @{u} &>/dev/null) && \
         [ "$(cd "$dep_dir" && git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" -gt 0 ]; then
        # Library has local unpushed commits!
        return 0
      fi
    done
  fi

  return 1
}

# ── Build deploy flags ────────────────────────────────────────
build_flags() {
  local flags=""
  $DRY_RUN   && flags="$flags --dry-run"
  $SKIP_PULL && flags="$flags --skip-pull"
  $NO_CACHE  && flags="$flags --no-cache"
  echo "$flags"
}

# ── Run a phase (build or deploy) for a single service ────────
# Generic runner — accepts the phase name and deploy.sh flag.
#   $1  svc         service directory name
#   $2  prefix      "true" to prefix output with colored service name
#   $3  phase       "build" | "deploy" (used for log/status filenames)
#   $4  phase_flag  "--build-only" | "--deploy-only"
run_phase() {
  local svc="$1"
  local prefix="$2"
  local phase="$3"
  local phase_flag="$4"
  local svc_dir="${ROOT_DIR}/${svc}"
  local log_file="${LOG_DIR}/${svc}.${phase}.log"
  local status_file="${LOG_DIR}/${svc}.${phase}.status"
  local flags
  flags=$(build_flags)

  if [ ! -f "${svc_dir}/deploy.sh" ]; then
    [ "$phase" = "build" ] && fail "${svc}: no deploy.sh found — skipping"
    echo "SKIP" > "$status_file"
    return 0
  fi

  local color="${SVC_COLORS[$svc]:-$DIM}"
  local pad_svc
  pad_svc=$(printf '%-20s' "$svc")

  # ── Export device-specific deploy vars for lib.sh ──────────
  local target="${SVC_DEPLOY_TARGET[$svc]:-synology}"
  export DEPLOY_TARGET="$target"
  export DEPLOY_METHOD="${DEVICE_METHOD[$target]:-ssh}"
  export DEPLOY_HOSTNAME="${DEVICE_HOSTNAME[$target]:-}"
  export DEPLOY_SSH_HOST="${DEVICE_SSH_ALIAS[$target]:-nas}"
  export DEPLOY_DOCKER_BIN="${DEVICE_DOCKER_BIN[$target]:-/usr/local/bin/docker}"
  export DEPLOY_DOCKER_API="${DEVICE_DOCKER_API[$target]:-}"
  export DEPLOY_COMPOSE_ROOT="${DEVICE_COMPOSE_ROOT[$target]:-/volume1/docker}"
  export DEPLOY_SMB_ROOT="${DEVICE_SMB_ROOT[$target]:-/mnt/k}"

  if [ "$prefix" = "true" ]; then
    # Prefix each line inline (no $(ts) subshell per line — this loop
    # runs for every line of build output across all parallel jobs)
    bash "${svc_dir}/deploy.sh" ${phase_flag} $flags 2>&1 \
      | tee "$log_file" \
      | while IFS= read -r line; do
          progress_percentage
          printf '%s%04ds %s %(%H:%M:%S)T%s %s%s[%s]%s %s\n' \
            "$DIM" "$(( SECONDS - ${DEPLOY_START:-$SECONDS} ))" "$PROGRESS_PCT" -1 "$RESET" \
            "$color" "$BOLD" "$pad_svc" "$RESET" "$line"
        done \
      && { echo "OK" > "$status_file"; } \
      || { echo "FAIL" > "$status_file"; }
  else
    bash "${svc_dir}/deploy.sh" ${phase_flag} $flags 2>&1 \
      | tee "$log_file" \
      && { echo "OK" > "$status_file"; } \
      || { echo "FAIL" > "$status_file"; }
  fi

  # ── Persist deploy SHA marker for non-docker-build services ──
  # Services that build local Docker images get a git.sha label
  # automatically (via lib.sh). Services using pre-built images
  # (e.g. qbittorrent-service) don't — so we persist the SHA to
  # a marker file for has_changes() to use on subsequent runs.
  # NEVER during --dry-run: deploy.sh no-ops report OK, and advancing
  # the markers without actually building would make the next real
  # run silently skip the library changes this service still needs.
  if ! $DRY_RUN && { [ "$phase" = "build" ] || [ "$phase" = "deploy" ] || [ "$phase" = "restart" ]; } && [ "$(cat "$status_file" 2>/dev/null)" = "OK" ]; then
    local current_sha
    current_sha=$(cd "$svc_dir" && git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$current_sha" ]; then
      echo "$current_sha" > "${DEPLOY_STATE_DIR}/${svc}.sha"
    fi

    # Persist the current git SHAs of all library dependencies
    if [ -n "${SVC_LIB_DEPS[$svc]:-}" ]; then
      local dep_file="${DEPLOY_STATE_DIR}/${svc}.deps.sha"
      rm -f "$dep_file"
      for dep_id in ${SVC_LIB_DEPS[$svc]}; do
        local dep_dir="${ROOT_DIR}/${dep_id}"
        local dep_sha
        dep_sha=$(cd "$dep_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$dep_sha" ]; then
          echo "${dep_id}: ${dep_sha}" >> "$dep_file"
        fi
      done
    fi
  fi
}

build_service()    { run_phase "$1" "$2" "build"    "--build-only";    }
deploy_service()   { run_phase "$1" "$2" "deploy"   "--deploy-only";   }
transfer_service() { run_phase "$1" "$2" "transfer" "--transfer-only"; }
restart_service()  { run_phase "$1" "$2" "restart"  "--restart-only";  }

# ── Build concurrency semaphore ───────────────────────────────
# Uses a FIFO pipe as a counting semaphore to cap the number of
# simultaneous docker builds to prevent CPU and I/O saturation.
# Without this, 25+ concurrent builds can overwhelm the system.
SEM_FIFO="${LOG_DIR}/.build-semaphore"
SSH_SEM_FIFO="${LOG_DIR}/.ssh-semaphore"

init_semaphore() {
  rm -f "$SEM_FIFO" "$SSH_SEM_FIFO"
  mkfifo "$SEM_FIFO"
  mkfifo "$SSH_SEM_FIFO"
  # Open a persistent read-write FD on the FIFOs.
  exec 7<>"$SEM_FIFO"
  exec 8<>"$SSH_SEM_FIFO"
  # Pre-fill with N tokens
  local i
  for ((i = 0; i < MAX_CONCURRENT_BUILDS; i++)); do
    echo "x" >&7
  done
  for ((i = 0; i < MAX_CONCURRENT_SSH; i++)); do
    echo "x" >&8
  done
}

sem_acquire() { read -r <&7; }
sem_release() { echo "x" >&7; }

sem_ssh_acquire() { read -r <&8; }
sem_ssh_release() { echo "x" >&8; }

# Wrapper: acquire semaphore → build → release
build_service_throttled() {
  local svc="$1"
  local prefix="$2"
  sem_acquire
  build_service "$svc" "$prefix"
  sem_release
}

# Wrapper: acquire semaphore → transfer → release
transfer_service_throttled() {
  local svc="$1"
  local prefix="$2"
  sem_ssh_acquire
  transfer_service "$svc" "$prefix"
  sem_ssh_release
}

# Wrapper: acquire semaphore → restart → release
restart_service_throttled() {
  local svc="$1"
  local prefix="$2"
  sem_ssh_acquire
  restart_service "$svc" "$prefix"
  sem_ssh_release
}

# ── Fire builds for a tier (non-blocking) ─────────────────────
# Launches all build jobs as background processes and stores PIDs.
# Does NOT wait — returns immediately so the next tier can fire too.
fire_builds() {
  local tier_name="$1"
  shift
  local services=("$@")
  local svc

  # Filter to only services we should deploy
  local filtered=()
  for svc in "${services[@]}"; do
    if should_deploy "$svc"; then
      if has_changes "$svc"; then
        filtered+=("$svc")
      else
        if [ "${IMPACT_VERDICT[$svc]:-}" = "unaffected" ]; then
          info "Skipping ${svc} — ${IMPACT_REASON[$svc]:-library changes not imported}"
        else
          info "Skipping ${svc} (unchanged since last build)"
        fi
        echo "SKIP" > "${LOG_DIR}/${svc}.build.status"
      fi
    else
      info "Skipping ${svc} (filtered)"
      echo "SKIP" > "${LOG_DIR}/${svc}.build.status"
    fi
  done

  if [ ${#filtered[@]} -eq 0 ]; then
    info "No services to build in ${tier_name}"
    return 0
  fi

  step "Launching builds — ${tier_name}: ${filtered[*]}"

  if $NO_PARALLEL; then
    # Sequential mode: run each build inline (blocking)
    for svc in "${filtered[@]}"; do
      build_service "$svc" "false"
      local status
      status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} built successfully"
      elif [ "$status" = "FAIL" ]; then
        fail "${svc} build failed"
        info "Log: ${LOG_DIR}/${svc}.build.log"
      fi
    done
  else
    # Parallel mode: throttled by semaphore (max $MAX_CONCURRENT_BUILDS)
    for svc in "${filtered[@]}"; do
      build_service_throttled "$svc" "true" &
      echo "$!" > "${LOG_DIR}/${svc}.build.pid"
      info "  ⟶ ${svc} (PID $!)"
    done
  fi
}

# ── Wait for a tier's builds to finish ────────────────────────
# Called just before deploying a tier. Collects exit status for
# each service that was launched in fire_builds.
wait_builds() {
  local tier_name="$1"
  shift
  local services=("$@")
  local svc

  # In sequential (--no-parallel) mode, builds already completed inline
  if $NO_PARALLEL; then
    return 0
  fi

  local any_waiting=false
  for svc in "${services[@]}"; do
    if [ -f "${LOG_DIR}/${svc}.build.pid" ]; then
      any_waiting=true
      break
    fi
  done

  if ! $any_waiting; then
    return 0
  fi

  step "Waiting for ${tier_name} builds to finish"

  local any_failed=false
  for svc in "${services[@]}"; do
    local pid_file="${LOG_DIR}/${svc}.build.pid"
    if [ ! -f "$pid_file" ]; then
      continue
    fi

    local pid
    pid=$(cat "$pid_file")
    wait "$pid" 2>/dev/null || true

    local status
    status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "OK" ]; then
      ok "${svc} built successfully"
    else
      fail "${svc} build failed → ${LOG_DIR}/${svc}.build.log"
      any_failed=true
    fi
  done

  if $any_failed; then
    warn "Some builds in ${tier_name} failed — check logs in ${LOG_DIR}/"
  fi
}

# ── Fire eager transfers (non-blocking) ───────────────────────
# For each service, launch a background job that polls for its
# build to complete, then immediately starts transferring the
# image. This overlaps transfers with builds still in progress.
fire_transfers() {
  local tier_name="$1"
  shift
  local services=("$@")

  if $NO_PARALLEL; then
    # In sequential mode, transfers happen inline during restart_tier
    return 0
  fi

  for svc in "${services[@]}"; do
    should_deploy "$svc" || continue

    (
      if [ -f "${LOG_DIR}/${svc}.build.pid" ]; then
        local build_process_pid
        build_process_pid=$(cat "${LOG_DIR}/${svc}.build.pid")
        while kill -0 "$build_process_pid" 2>/dev/null; do
          sleep 1
        done
      fi

      while [ ! -f "${LOG_DIR}/${svc}.build.status" ]; do
        sleep 1
      done

      local build_status
      build_status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$build_status" != "OK" ]; then
        echo "SKIP" > "${LOG_DIR}/${svc}.transfer.status"
        exit 0
      fi

      transfer_service_throttled "$svc" "true"
    ) &
    echo "$!" > "${LOG_DIR}/${svc}.transfer.pid"
  done
}

# ── Wait for a tier's transfers to finish ─────────────────────
wait_transfers() {
  local tier_name="$1"
  shift
  local services=("$@")

  if $NO_PARALLEL; then
    return 0
  fi

  local any_waiting=false
  for svc in "${services[@]}"; do
    if [ -f "${LOG_DIR}/${svc}.transfer.pid" ]; then
      any_waiting=true
      break
    fi
  done

  if ! $any_waiting; then
    return 0
  fi

  step "Waiting for ${tier_name} transfers to finish"

  local any_failed=false
  for svc in "${services[@]}"; do
    local pid_file="${LOG_DIR}/${svc}.transfer.pid"
    if [ ! -f "$pid_file" ]; then
      continue
    fi

    local pid
    pid=$(cat "$pid_file")
    wait "$pid" 2>/dev/null || true

    local status
    status=$(cat "${LOG_DIR}/${svc}.transfer.status" 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "OK" ]; then
      ok "${svc} transferred successfully"
    elif [ "$status" = "SKIP" ]; then
      continue
    else
      fail "${svc} transfer failed → ${LOG_DIR}/${svc}.transfer.log"
      any_failed=true
    fi
  done

  if $any_failed; then
    warn "Some transfers in ${tier_name} failed — check logs in ${LOG_DIR}/"
  fi
}

# ── Restart a tier (compose up only — images already on target) ─
restart_tier() {
  local tier_name="$1"
  shift
  local services=("$@")

  # Filter to only services whose transfer (or build in seq mode) succeeded
  local filtered=()
  for svc in "${services[@]}"; do
    if ! should_deploy "$svc"; then
      echo "SKIP" > "${LOG_DIR}/${svc}.deploy.status"
      continue
    fi

    if $NO_PARALLEL; then
      # Sequential mode: check build status (transfer hasn't run yet)
      local build_status
      build_status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "SKIP")
      if [ "$build_status" = "OK" ]; then
        filtered+=("$svc")
      elif [ "$build_status" = "FAIL" ]; then
        fail "${svc}: build failed — skipping"
        echo "FAIL" > "${LOG_DIR}/${svc}.deploy.status"
      else
        echo "SKIP" > "${LOG_DIR}/${svc}.deploy.status"
      fi
    else
      # Parallel mode: check transfer status
      local transfer_status
      transfer_status=$(cat "${LOG_DIR}/${svc}.transfer.status" 2>/dev/null || echo "SKIP")
      if [ "$transfer_status" = "OK" ]; then
        filtered+=("$svc")
      elif [ "$transfer_status" = "FAIL" ]; then
        fail "${svc}: transfer failed — skipping"
        echo "FAIL" > "${LOG_DIR}/${svc}.deploy.status"
      else
        # Transfer was skipped — check if the underlying build failed
        local _underlying_build
        _underlying_build=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "SKIP")
        if [ "$_underlying_build" = "FAIL" ]; then
          fail "${svc}: build failed — skipping"
          echo "FAIL" > "${LOG_DIR}/${svc}.deploy.status"
        else
          echo "SKIP" > "${LOG_DIR}/${svc}.deploy.status"
        fi
      fi
    fi
  done

  if [ ${#filtered[@]} -eq 0 ]; then
    info "No services to restart in ${tier_name}"
    return 0
  fi

  step "Restarting ${tier_name}: ${filtered[*]}"

  if $NO_PARALLEL || [ ${#filtered[@]} -eq 1 ]; then
    for svc in "${filtered[@]}"; do
      if $NO_PARALLEL; then
        # Sequential: do full deploy (transfer + restart in one shot)
        deploy_service "$svc" "false"
        local status
        status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "UNKNOWN")
      else
        restart_service "$svc" "false"
        local status
        status=$(cat "${LOG_DIR}/${svc}.restart.status" 2>/dev/null || echo "UNKNOWN")
        echo "$status" > "${LOG_DIR}/${svc}.deploy.status"
      fi
      if [ "$status" = "OK" ]; then
        ok "${svc} restarted successfully"
      elif [ "$status" = "FAIL" ]; then
        fail "${svc} restart failed"
        if [ "$tier_name" = "Tier 0 — Foundation" ]; then
          fail "Vault restart failed — aborting all subsequent tiers"
          return 1
        fi
      fi
    done
  else
    # Parallel restart within tier
    local pids=()
    for svc in "${filtered[@]}"; do
      restart_service_throttled "$svc" "true" &
      pids+=("$!:$svc")
    done

    local any_failed=false
    for entry in "${pids[@]}"; do
      local pid="${entry%%:*}"
      local svc="${entry##*:}"
      wait "$pid" 2>/dev/null || true
      local status
      status=$(cat "${LOG_DIR}/${svc}.restart.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} restarted successfully"
        echo "OK" > "${LOG_DIR}/${svc}.deploy.status"
      else
        fail "${svc} restart failed → ${LOG_DIR}/${svc}.restart.log"
        echo "FAIL" > "${LOG_DIR}/${svc}.deploy.status"
        any_failed=true
      fi
    done

    if $any_failed; then
      warn "Some restarts in ${tier_name} failed — check logs in ${LOG_DIR}/"
      # Tier 0 failure is fatal — vault must succeed
      if [ "$tier_name" = "Tier 0 — Foundation" ]; then
        fail "Vault restart failed — aborting all subsequent tiers"
        return 1
      fi
    fi
  fi
}

# ── Health-gate: wait for a tier to become healthy ────────────
# After deploying a tier, poll health endpoints until all services
# respond 2xx or timeout. Prevents boot-order races where later
# tiers start before their dependencies are ready.
#
# All services are polled CONCURRENTLY in a single loop so the
# timeout applies to the whole tier (worst case 60s total), not
# per-service (which was N × 60s sequential).
HEALTH_GATE_TIMEOUT=60    # seconds for the entire tier
HEALTH_GATE_INTERVAL=3    # seconds between poll rounds

wait_tier_healthy() {
  local tier_name="$1"
  shift
  local services=("$@")

  # Only gate services that were actually deployed
  local to_check=()
  for svc in "${services[@]}"; do
    local deploy_status
    deploy_status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "SKIP")
    if [ "$deploy_status" = "OK" ] && [ -n "${SVC_HEALTH_URL[$svc]:-}" ]; then
      to_check+=("$svc")
    fi
  done

  if [ ${#to_check[@]} -eq 0 ]; then
    return 0
  fi

  step "Health gate — waiting for ${tier_name} services to become healthy"

  # Track which services are still pending
  declare -A pending
  for svc in "${to_check[@]}"; do
    pending[$svc]=1
  done

  # Deadline-based timeout so curl time counts against the budget,
  # and pid-specific wait so we never block on unrelated background
  # jobs (later-tier builds/transfers are still running at this point).
  local deadline=$(( SECONDS + HEALTH_GATE_TIMEOUT ))
  local all_healthy=true

  while [ ${#pending[@]} -gt 0 ] && [ "$SECONDS" -lt "$deadline" ]; do
    # Fire all health checks in parallel (background curl per service)
    local check_dir
    local curl_pids=()
    check_dir=$(mktemp -d "${LOG_DIR}/.health-XXXXXX")
    for svc in "${!pending[@]}"; do
      local url="${SVC_HEALTH_URL[$svc]}"
      ( curl -sf --max-time 3 -o /dev/null "$url" 2>/dev/null && echo "OK" > "${check_dir}/${svc}" ) &
      curl_pids+=("$!")
    done
    wait "${curl_pids[@]}" 2>/dev/null || true

    # Collect results
    local newly_healthy=()
    for svc in "${!pending[@]}"; do
      if [ -f "${check_dir}/${svc}" ]; then
        newly_healthy+=("$svc")
      fi
    done
    rm -rf "$check_dir"

    # Remove healthy services from the pending set
    for svc in "${newly_healthy[@]}"; do
      ok "${svc} healthy (${SVC_HEALTH_URL[$svc]})"
      echo "OK" > "${LOG_DIR}/${svc}.health.status"
      unset "pending[$svc]"
    done

    # If all healthy, we're done
    if [ ${#pending[@]} -eq 0 ]; then
      break
    fi

    sleep $HEALTH_GATE_INTERVAL
  done

  # Report any services that never became healthy
  for svc in "${!pending[@]}"; do
    warn "${svc} not healthy after ${HEALTH_GATE_TIMEOUT}s — proceeding anyway"
    echo "UNHEALTHY" > "${LOG_DIR}/${svc}.health.status"
    all_healthy=false
  done

  if $all_healthy; then
    ok "All ${tier_name} services healthy ✓"
  fi
}

# ── Timer ─────────────────────────────────────────────────────
DEPLOY_START=$SECONDS


# ── Header ────────────────────────────────────────────────────
echo ""
rule "$MAGENTA"
printf '%s%s  🚀  Deploy All Services%s\n' "$MAGENTA" "$BOLD" "$RESET"
printf '  %sThree-phase pipeline: build → transfer → restart%s\n' "$DIM" "$RESET"
if $DRY_RUN; then
  printf '%s%s  ⚠  DRY RUN — no changes will be made%s\n' "$YELLOW" "$BOLD" "$RESET"
fi
if [ -n "$GROUP" ]; then
  printf '  %sGroup: %s%s\n' "$CYAN" "$GROUP" "$RESET"
fi
if [ -n "$ONLY" ]; then
  printf '  %sOnly: %s%s\n' "$CYAN" "$ONLY" "$RESET"
fi
if [ -n "$SKIP_LIST" ]; then
  printf '  %sSkipping: %s%s\n' "$CYAN" "$SKIP_LIST" "$RESET"
fi
if $CHANGED_ONLY; then
  printf '  %sMode: changed-only (skipping unchanged services)%s\n' "$CYAN" "$RESET"
  if ! $SKIP_DEPS && ! $NO_IMPACT; then
    printf '  %sImpact: symbol-level library analysis on (--no-impact to disable)%s\n' "$CYAN" "$RESET"
  fi
fi
if $SKIP_DEPS; then
  printf '  %sMode: skip-deps (skipping library sync and dependency change checks)%s\n' "$CYAN" "$RESET"
fi
if $BUILD_ONLY; then
  printf '%s%s  ⚠  BUILD ONLY — no transfer or restart will be performed%s\n' "$YELLOW" "$BOLD" "$RESET"
fi
if $VAULT_CONFIG_CHANGED; then
  printf '  %s%s⚡ projects.json changed — vault-service will be force-deployed%s\n' "$YELLOW" "$BOLD" "$RESET"
fi
rule "$MAGENTA"

# ── Prepare log directory ─────────────────────────────────────
mkdir -p "$LOG_DIR"
rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/*.status "${LOG_DIR}"/*.pid "${LOG_DIR}"/.build-semaphore "${LOG_DIR}"/.ssh-semaphore 2>/dev/null
rm -rf "${LOG_DIR}"/.health-* 2>/dev/null

# Initialize build concurrency semaphore
if ! $NO_PARALLEL; then
  init_semaphore
fi

# ══════════════════════════════════════════════════════════════
# PHASE 0 — LIBRARY SYNC
# Shared libraries build their dist/ automatically via git pre-commit
# hooks. This phase pulls latest to ensure the local developer
# workspace is in sync and checks for any changes (remote or local)
# to trigger downstream dependency updates.
# ══════════════════════════════════════════════════════════════

# Discover library projects dynamically (topological order scanned from package.json)
# LIBRARY_IDS was already populated dynamically at startup

if [ ${#LIBRARY_IDS[@]} -gt 0 ] && ! $DRY_RUN && ! $SKIP_DEPS; then
  box "$YELLOW" "PHASE 0 — LIBRARY SYNC" "Pull latest shared libraries and check for changes"

  # Pre-pull all libraries in parallel to reduce sequential network latency
  declare -A PULL_OUTPUTS
  declare -A PULLED_CHANGES
  if ! $SKIP_PULL; then
    step "Pre-pulling libraries in parallel"
    pull_pids=()
    for lib_id in "${LIBRARY_IDS[@]}"; do
      lib_dir="${ROOT_DIR}/${lib_id}"
      [ -d "$lib_dir" ] || continue
      pull_log="${LOG_DIR}/${lib_id}.pull.log"
      (cd "$lib_dir" && git pull --ff-only > "$pull_log" 2>&1) &
      pull_pids+=("$!:$lib_id:$pull_log")
    done

    for entry in "${pull_pids[@]}"; do
      pid="${entry%%:*}"
      rest="${entry#*:}"
      lib_id="${rest%%:*}"
      pull_log="${rest#*:}"
      wait "$pid" 2>/dev/null || true
      if [ -f "$pull_log" ]; then
        output=$(cat "$pull_log")
        PULL_OUTPUTS[$lib_id]="$output"
        if echo "$output" | grep -q -vE "Already up to date|Current branch.*is up to date|^[[:space:]]*$"; then
          PULLED_CHANGES[$lib_id]=true
        else
          PULLED_CHANGES[$lib_id]=false
        fi
        rm -f "$pull_log"
      else
        PULLED_CHANGES[$lib_id]=true
      fi
    done
  fi

  ANY_LIB_CHANGED=false

  for lib_id in "${LIBRARY_IDS[@]}"; do
    lib_dir="${ROOT_DIR}/${lib_id}"
    if [ ! -d "$lib_dir" ]; then
      warn "${lib_id}: directory not found — skipping"
      continue
    fi

    step "Syncing ${lib_id}"

    # Print parallel pre-pulled output
    if ! $SKIP_PULL; then
      if [ -n "${PULL_OUTPUTS[$lib_id]:-}" ]; then
        echo "${PULL_OUTPUTS[$lib_id]}" | sed 's/^/  /'
      fi
    fi

    # Check for local uncommitted changes OR unpushed commits
    _has_changes=false
    if ! (cd "$lib_dir" && git diff --quiet HEAD -- . 2>/dev/null) || \
       [ -n "$(cd "$lib_dir" && git ls-files --others --exclude-standard . 2>/dev/null)" ]; then
      _has_changes=true
    elif (cd "$lib_dir" && git rev-parse --abbrev-ref @{u} &>/dev/null) && \
         [ "$(cd "$lib_dir" && git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" -gt 0 ]; then
      _has_changes=true
    fi

    if [ "${PULLED_CHANGES[$lib_id]:-false}" = "true" ]; then
      ok "${lib_id}: pulled latest changes from remote"
      ANY_LIB_CHANGED=true
    elif $_has_changes; then
      info "${lib_id}: has local changes or unpushed commits (will trigger downstream rebuilds)"
      ANY_LIB_CHANGED=true
    else
      ok "${lib_id}: up to date (no changes)"
    fi
  done
fi

# ══════════════════════════════════════════════════════════════
# PHASE 0.5 — LIBRARY IMPACT ANALYSIS (symbol-level)
# Instead of rebuilding every consumer whenever a library repo
# gains a commit, scripts/lib-impact.js maps the changed library
# files through the library's internal import graph to the exact
# export surface (subpaths, barrel symbols, css) that changed,
# then intersects that with what each service actually imports.
# Services whose imports are untouched are skipped.
# Anything the analysis cannot classify fails OPEN (= rebuild),
# and any script failure falls back to the legacy behavior.
# ══════════════════════════════════════════════════════════════
declare -A IMPACT_VERDICT
declare -A IMPACT_REASON
IMPACT_SCRIPT_OK=false
if $CHANGED_ONLY && ! $SKIP_DEPS && ! $NO_IMPACT; then
  # Pair list "svc:lib1,lib2;svc2:lib1;..." — bash owns which libs
  # each service tracks (SVC_LIB_DEPS); the script owns the verdicts.
  _impact_pairs=""
  for svc in "${ALL_SERVICES[@]}"; do
    [ -n "${SVC_LIB_DEPS[$svc]:-}" ] || continue
    _impact_pairs="${_impact_pairs}${svc}:${SVC_LIB_DEPS[$svc]// /,};"
  done

  if [ -n "$_impact_pairs" ]; then
    step "Analyzing library change impact (symbol-level)"
    if _impact_eval=$(node "${SCRIPT_DIR}/scripts/lib-impact.js" \
        --root "$ROOT_DIR" \
        --state "$DEPLOY_STATE_DIR" \
        --projects "$PROJECTS_JSON" \
        --pairs "$_impact_pairs" \
        2>"${LOG_DIR}/impact.log"); then
      eval "$_impact_eval"
    else
      warn "lib-impact.js failed — using legacy whole-library change detection"
    fi

    # Surface the script's summary/warning lines
    if [ -s "${LOG_DIR}/impact.log" ]; then
      while IFS= read -r _impact_line; do
        case "$_impact_line" in
          impact-warn:*) warn "${_impact_line#impact-warn: }" ;;
          impact:*)      info "${_impact_line#impact: }" ;;
          *)             info "$_impact_line" ;;
        esac
      done < "${LOG_DIR}/impact.log"
    fi
  fi
fi

# ── Validate all services have deploy.sh ──────────────────────
step "Pre-flight check"
MISSING=()
for svc in "${ALL_SERVICES[@]}"; do
  if should_deploy "$svc"; then
    if [ -f "${ROOT_DIR}/${svc}/deploy.sh" ]; then
      ok "${svc}/deploy.sh"
    else
      fail "${svc}/deploy.sh not found"
      MISSING+=("$svc")
    fi
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  warn "Missing deploy scripts: ${MISSING[*]}"
  warn "These services will be skipped"
fi

# ── Pre-flight: prune orphaned Docker networks on deploy targets ──
# Docker has a limited pool of /16 subnets for bridge networks.
# Old/renamed services leave behind orphaned networks that exhaust
# the pool, causing "could not find an available IPv4 address pool"
# errors during deploy. Pruning unused networks prevents this.
if ! $DRY_RUN; then
  # Collect unique SSH-based deploy targets
  declare -A _prune_hosts
  for svc in "${ALL_SERVICES[@]}"; do
    local_target="${SVC_DEPLOY_TARGET[$svc]:-synology}"
    local_method="${DEVICE_METHOD[$local_target]:-ssh}"
    if [ "$local_method" = "ssh" ]; then
      _prune_hosts[$local_target]="${DEVICE_SSH_ALIAS[$local_target]:-nas}"
    fi
  done

  for _target_id in "${!_prune_hosts[@]}"; do
    _ssh_host="${_prune_hosts[$_target_id]}"
    _docker_bin="${DEVICE_DOCKER_BIN[$_target_id]:-/usr/local/bin/docker}"
    step "Pruning orphaned Docker networks on ${_target_id} (${_ssh_host})"
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$_ssh_host" "true" 2>/dev/null; then
      PRUNED=$(ssh "$_ssh_host" "sudo ${_docker_bin} network prune -f 2>&1" || true)
      PRUNED_NAMES=$(echo "$PRUNED" | grep -v "Deleted Networks:" | grep -v "Total reclaimed" | grep -v "^$" | tr '\n' ' ' || true)
      if [ -n "$PRUNED_NAMES" ]; then
        ok "Pruned: ${PRUNED_NAMES}"
      else
        ok "No orphaned networks"
      fi
    else
      warn "Cannot reach ${_target_id} via SSH — skipping network prune"
    fi
  done
fi

# ── Tier labels (descriptive names for output) ───────────────
declare -A TIER_LABELS=(
  [0]="Tier 0 — Foundation"
  [1]="Tier 1 — Services & Clients"
  [2]="Tier 2 — Bots"
)

# ══════════════════════════════════════════════════════════════
# PRE-BUILD — Dangling image cleanup only
# BuildKit cache is nuked once in Phase 3 after deploy completes.
# Pre-build, we only clean dangling images (instant) to free
# layer refs before the build phase starts.
# ══════════════════════════════════════════════════════════════
if ! $DRY_RUN; then
  docker image prune -f 2>/dev/null | grep -v 'Total reclaimed space: 0B' | sed 's/^/  /' || true
fi

# ══════════════════════════════════════════════════════════════
# PHASE 1 — BUILD ALL (fire all tiers simultaneously)
# ══════════════════════════════════════════════════════════════
box "$CYAN" "PHASE 1 — BUILD" "All services build in parallel across all tiers"


# Fire all builds at once — no waiting between tiers
for tier in $(seq 0 "$MAX_TIER"); do
  tier_label="${TIER_LABELS[$tier]:-Tier $tier}"
  # shellcheck disable=SC2206
  tier_svcs=(${TIER_SERVICES[$tier]})
  if [ ${#tier_svcs[@]} -gt 0 ]; then
    fire_builds "$tier_label" "${tier_svcs[@]}"
  fi
done

# Fire eager transfers — each polls for its own build, then
# starts transferring immediately. This overlaps image transfers
# with builds still in progress (pipeline parallelism).
if ! $BUILD_ONLY; then
  for tier in $(seq 0 "$MAX_TIER"); do
    tier_label="${TIER_LABELS[$tier]:-Tier $tier}"
    # shellcheck disable=SC2206
    tier_svcs=(${TIER_SERVICES[$tier]})
    if [ ${#tier_svcs[@]} -gt 0 ]; then
      fire_transfers "$tier_label" "${tier_svcs[@]}"
    fi
  done
fi

if ! $NO_PARALLEL && ! $BUILD_ONLY; then
  echo ""
  info "All builds + transfers launched — transfers start as builds complete"
fi

# ── BUILD_ONLY: wait for all builds, report, and exit ─────────
if $BUILD_ONLY; then
  echo ""
  info "Build-only mode — waiting for all builds to complete..."

  # Wait for all tier builds
  for tier in $(seq 0 "$MAX_TIER"); do
    tier_label="${TIER_LABELS[$tier]:-Tier $tier}"
    # shellcheck disable=SC2206
    tier_svcs=(${TIER_SERVICES[$tier]})
    if [ ${#tier_svcs[@]} -gt 0 ]; then
      wait_builds "$tier_label" "${tier_svcs[@]}"
    fi
  done

  # Summary
  TOTAL=$((SECONDS - DEPLOY_START))
  echo ""
  rule "$MAGENTA"
  printf '%s%s  🔨  Build Only — Summary%s\n' "$MAGENTA" "$BOLD" "$RESET"
  rule "$MAGENTA"

  PASS=0
  FAILED=0
  SKIPPED=0

  for svc in "${ALL_SERVICES[@]}"; do
    local_status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "SKIP")
    svc_clr="${SVC_COLORS[$svc]:-$DIM}"
    case "$local_status" in
      OK)   printf '  %s✔ %s%s\n' "$svc_clr" "$svc" "$RESET"; PASS=$((PASS + 1)) ;;
      FAIL) printf '  %s✖ %s%s  →  %s %s(build failed)%s\n' "$RED" "$svc" "$RESET" "${LOG_DIR}/${svc}.build.log" "$DIM" "$RESET"; FAILED=$((FAILED + 1)) ;;
      *)    printf '  %s⊘ %s (skipped)%s\n' "$DIM" "$svc" "$RESET"; SKIPPED=$((SKIPPED + 1)) ;;
    esac
  done

  echo ""
  printf '  %s%s passed%s  %s%s failed%s  %s%s skipped%s\n' "$GREEN" "$PASS" "$RESET" "$RED" "$FAILED" "$RESET" "$DIM" "$SKIPPED" "$RESET"
  printf '  %sTotal: %dm %02ds%s\n' "$DIM" "$((TOTAL / 60))" "$((TOTAL % 60))" "$RESET"
  printf '  %s%s%s\n' "$DIM" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$RESET"
  echo ""
  rule "$MAGENTA"

  [ "$FAILED" -eq 0 ]
  exit
fi

# ══════════════════════════════════════════════════════════════
# PRE-DEPLOY — Cross-device orphan container teardown
# When a project moves between devices (e.g. synology → workstation2),
# the old container would keep running. Before deploying, check ALL
# Docker-capable devices (except the target) for a container with
# the same name and tear it down.
# ══════════════════════════════════════════════════════════════
if ! $DRY_RUN && [ ${#DOCKER_DEVICES[@]} -gt 1 ]; then
  box "$YELLOW" "PRE-DEPLOY — Cross-device orphan teardown" "Checking other devices for stale containers"

  # Fetch each device's full container list ONCE (also serves as the
  # reachability probe). Membership checks then happen in bash — this
  # replaces one SSH/docker round-trip per service per device.
  declare -A _device_reachable
  declare -A _device_containers   # device-id -> newline-separated container names
  for _dev in "${DOCKER_DEVICES[@]}"; do
    _dev_method="${DEVICE_METHOD[$_dev]:-ssh}"
    _names=""
    if [ "$_dev_method" = "docker-api" ]; then
      _dev_api="${DEVICE_DOCKER_API[$_dev]:-}"
      if [ -n "$_dev_api" ] && _names=$(docker -H "$_dev_api" ps -a --format '{{.Names}}' 2>/dev/null); then
        _device_reachable[$_dev]="true"
      else
        _device_reachable[$_dev]="false"
        warn "Cannot reach ${_dev} via Docker API — skipping orphan check"
      fi
    else
      _dev_ssh="${DEVICE_SSH_ALIAS[$_dev]:-}"
      _dev_docker_bin="${DEVICE_DOCKER_BIN[$_dev]:-/usr/local/bin/docker}"
      if [ -n "$_dev_ssh" ] && _names=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$_dev_ssh" "sudo ${_dev_docker_bin} ps -a --format '{{.Names}}'" 2>/dev/null); then
        _device_reachable[$_dev]="true"
      else
        _device_reachable[$_dev]="false"
        warn "Cannot reach ${_dev} via SSH — skipping orphan check"
      fi
    fi
    _device_containers[$_dev]="$_names"
  done

  for svc in "${ALL_SERVICES[@]}"; do
    should_deploy "$svc" || continue

    local_target="${SVC_DEPLOY_TARGET[$svc]:-synology}"

    for _dev in "${DOCKER_DEVICES[@]}"; do
      # Skip the device this service is deploying TO
      [ "$_dev" = "$local_target" ] && continue
      # Skip unreachable devices
      [ "${_device_reachable[$_dev]:-false}" = "true" ] || continue
      # Skip devices that don't have a container by this exact name
      case $'\n'"${_device_containers[$_dev]}"$'\n' in
        *$'\n'"$svc"$'\n'*) ;;
        *) continue ;;
      esac

      warn "Found orphan container '${svc}' on ${_dev} — tearing down"
      _dev_method="${DEVICE_METHOD[$_dev]:-ssh}"

      if [ "$_dev_method" = "docker-api" ]; then
        _dev_api="${DEVICE_DOCKER_API[$_dev]:-}"
        docker -H "$_dev_api" rm -f "$svc" 2>/dev/null || true
        # Also try compose down if a compose dir exists
        _dev_compose_root="${DEVICE_COMPOSE_ROOT[$_dev]:-}"
        if [ -n "$_dev_compose_root" ]; then
          DOCKER_HOST="$_dev_api" docker compose -f "${_dev_compose_root}/${svc}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
        fi
      else
        _dev_ssh="${DEVICE_SSH_ALIAS[$_dev]:-}"
        _dev_docker_bin="${DEVICE_DOCKER_BIN[$_dev]:-/usr/local/bin/docker}"
        _dev_compose_root="${DEVICE_COMPOSE_ROOT[$_dev]:-}"
        if [ -n "$_dev_compose_root" ]; then
          ssh "$_dev_ssh" "cd '${_dev_compose_root}/${svc}' 2>/dev/null && sudo ${_dev_docker_bin} compose down --remove-orphans 2>&1 || sudo ${_dev_docker_bin} rm -f '${svc}' 2>&1" 2>/dev/null || true
        else
          ssh "$_dev_ssh" "sudo ${_dev_docker_bin} rm -f '${svc}'" 2>/dev/null || true
        fi
      fi
      ok "Orphan '${svc}' removed from ${_dev}"
    done
  done

  ok "Cross-device orphan check complete"
fi

# ══════════════════════════════════════════════════════════════
# PHASE 2 — WAIT & RESTART IN ORDER
# ══════════════════════════════════════════════════════════════
box "$GREEN" "PHASE 2 — RESTART" "Wait for transfers, then restart tier-by-tier"


for tier in $(seq 0 "$MAX_TIER"); do
  tier_label="${TIER_LABELS[$tier]:-Tier $tier}"
  # shellcheck disable=SC2206
  tier_svcs=(${TIER_SERVICES[$tier]})
  if [ ${#tier_svcs[@]} -eq 0 ]; then
    continue
  fi

  header "━━━ ${tier_label} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Wait for this tier's transfers to land on the target
  wait_transfers "$tier_label" "${tier_svcs[@]}"

  # Restart containers (images are already on target)
  if ! restart_tier "$tier_label" "${tier_svcs[@]}"; then
    if [ "$tier" -eq 0 ]; then
      fail "Aborting deployment — foundation tier failed"
      exit 1
    fi
  fi

  # Health-gate: wait for this tier's services to become healthy
  # before restarting the next tier (skip for the last tier).
  if [ "$tier" -lt "$MAX_TIER" ] && ! $DRY_RUN; then
    wait_tier_healthy "$tier_label" "${tier_svcs[@]}"
  fi
done


# ══════════════════════════════════════════════════════════════
# PHASE 3 — LOCAL IMAGE CLEANUP
# Remove SHA-tagged images (keep only :latest per service for
# --changed-only SHA label detection), prune dangling layers,
# and clear BuildKit build cache to prevent WSL2 VHDX growth.
# ══════════════════════════════════════════════════════════════
if ! $DRY_RUN; then
  box "$YELLOW" "PHASE 3 — LOCAL IMAGE CLEANUP" "Remove stale tags, dangling layers, and build cache"

  # Remove all tags except :latest (needed for --changed-only).
  # One docker listing + one batched rmi instead of a call per service.
  declare -A _svc_set
  for svc in "${ALL_SERVICES[@]}"; do _svc_set[$svc]=1; done
  stale_tags=()
  while IFS=: read -r _repo _tag; do
    if [ -n "${_svc_set[$_repo]:-}" ] && [ "$_tag" != "latest" ]; then
      stale_tags+=("${_repo}:${_tag}")
    fi
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

  CLEANED=${#stale_tags[@]}
  if [ "$CLEANED" -gt 0 ]; then
    docker rmi "${stale_tags[@]}" >/dev/null 2>&1 || true
  fi

  # Prune dangling images
  PRUNE_OUTPUT=$(docker image prune -f 2>/dev/null || true)
  RECLAIMED=$(echo "$PRUNE_OUTPUT" | grep 'Total reclaimed space' || echo "0B reclaimed")

  if [ "$CLEANED" -gt 0 ]; then
    ok "Removed ${CLEANED} stale local image tags — ${RECLAIMED}"
  else
    ok "No stale local images to clean"
  fi

  # ── Prune BuildKit build cache ──────────────────────────────
  # Nuke all build cache after deploy. This is the ONLY cache prune
  # in the pipeline (pre-build prune was removed — it was redundant).
  # Every deploy gets cold builds, but prevents unbounded VHDX growth.
  step "Pruning all BuildKit build cache"
  BUILDER_PRUNE_OUTPUT=$(docker builder prune -f --all 2>/dev/null || true)
  BUILDER_RECLAIMED=$(echo "$BUILDER_PRUNE_OUTPUT" | grep 'Total reclaimed space' || echo "0B reclaimed")
  ok "Build cache pruned — ${BUILDER_RECLAIMED}"

  # ── Optional: compact WSL2 VHDX ─────────────────────────────
  # Docker data lives in WSL2's ext4.vhdx which grows but never
  # auto-shrinks. After pruning, reclaim Windows disk space by
  # compacting the VHDX via PowerShell. Use --compact-wsl flag.
  if $COMPACT_WSL; then
    step "Compacting WSL2 virtual disk (VHDX)"
    # Find the Docker Desktop VHDX path
    _raw_vhdx_path=$(find /mnt/c/Users/*/AppData/Local/Docker/wsl/disk -name 'docker_data.vhdx' 2>/dev/null | head -1)
    VHDX_PATH=$(wslpath -w "$_raw_vhdx_path" 2>/dev/null || true)
    if [ -z "$VHDX_PATH" ]; then
      # Fallback: try the standard docker-desktop-data distro path
      _ps_command="Get-ChildItem -Path \$env:LOCALAPPDATA\\Docker\\wsl\\disk -Filter 'docker_data.vhdx' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1"
      VHDX_PATH=$(powershell.exe -Command "$_ps_command" 2>/dev/null | tr -d '\r' || true)
    fi
    if [ -n "$VHDX_PATH" ]; then
      info "VHDX: ${VHDX_PATH}"
      info "Shutting down WSL to release locks..."
      wsl.exe --shutdown 2>/dev/null || true
      sleep 3
      # Compact via PowerShell (no interactive diskpart needed)
      powershell.exe -Command "Optimize-VHD -Path '${VHDX_PATH}' -Mode Full" 2>/dev/null && \
        ok "VHDX compacted successfully" || \
        warn "VHDX compaction failed — you may need to run as Administrator"
    else
      warn "Could not locate Docker VHDX — skipping compaction"
      info "You can compact manually: wsl --shutdown && diskpart → select vdisk → compact vdisk"
    fi
  fi
fi


# ── Summary ───────────────────────────────────────────────────
TOTAL=$((SECONDS - DEPLOY_START))

echo ""
rule "$MAGENTA"
printf '%s%s  ☀️  Deploy All — Summary%s\n' "$MAGENTA" "$BOLD" "$RESET"
rule "$MAGENTA"

PASS=0
FAILED=0
SKIPPED=0
UNHEALTHY_COUNT=0

for svc in "${ALL_SERVICES[@]}"; do
  local_status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "SKIP")
  svc_clr="${SVC_COLORS[$svc]:-$DIM}"
  case "$local_status" in
    OK)
      if [ "$(cat "${LOG_DIR}/${svc}.health.status" 2>/dev/null)" = "UNHEALTHY" ]; then
        printf '  %s⚠ %s (unhealthy)%s\n' "$YELLOW" "$svc" "$RESET"
        UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
      else
        printf '  %s✔ %s%s\n' "$svc_clr" "$svc" "$RESET"
        PASS=$((PASS + 1))
      fi
      ;;
    FAIL)
      # Show correct log based on what actually failed
      if [ -f "${LOG_DIR}/${svc}.deploy.log" ]; then
        printf '  %s✖ %s%s  →  %s\n' "$RED" "$svc" "$RESET" "${LOG_DIR}/${svc}.deploy.log"
      elif [ "$(cat "${LOG_DIR}/${svc}.restart.status" 2>/dev/null)" = "FAIL" ]; then
        printf '  %s✖ %s%s  →  %s %s(restart failed)%s\n' "$RED" "$svc" "$RESET" "${LOG_DIR}/${svc}.restart.log" "$DIM" "$RESET"
      elif [ "$(cat "${LOG_DIR}/${svc}.transfer.status" 2>/dev/null)" = "FAIL" ]; then
        printf '  %s✖ %s%s  →  %s %s(transfer failed)%s\n' "$RED" "$svc" "$RESET" "${LOG_DIR}/${svc}.transfer.log" "$DIM" "$RESET"
      else
        printf '  %s✖ %s%s  →  %s %s(build failed)%s\n' "$RED" "$svc" "$RESET" "${LOG_DIR}/${svc}.build.log" "$DIM" "$RESET"
      fi
      FAILED=$((FAILED + 1))
      ;;
    *)    printf '  %s⊘ %s (skipped)%s\n' "$DIM" "$svc" "$RESET"; SKIPPED=$((SKIPPED + 1)) ;;
  esac
done

# ── Edge DNS + config sync ───────────────────────────────────
# Registry domain changes reach DNS and the live edge proxy on every
# deploy: reconcile records first (create new, prune ownership-manifest
# entries no longer in the registry — see edge/dns-ownership.json), then
# hot-reload routes so certs can issue for new names. Best-effort: an
# edge hiccup must never fail the service deploy run. Both steps no-op
# unless the edge is enabled (+ proxyMode caddy for the route sync).
if edge_dns_output=$(node "${SCRIPT_DIR}/edge/reconcile-dns.js" --apply 2>&1); then
  edge_dns_summary=$(printf '%s\n' "$edge_dns_output" | grep -E "in place|created|pruned" | tail -1)
  [ -n "$edge_dns_summary" ] && printf '  %sedge dns: %s%s\n' "$DIM" "$edge_dns_summary" "$RESET"
else
  printf '  %s⚠ edge dns reconcile reported conflicts (services deployed fine) — run npm run edge:dns:check%s\n' "$YELLOW" "$RESET"
fi
if edge_sync_output=$(bash "${SCRIPT_DIR}/edge/sync-config.sh" 2>&1); then
  [ -n "$edge_sync_output" ] && printf '  %s%s%s\n' "$DIM" "$edge_sync_output" "$RESET"
else
  printf '  %s⚠ edge config sync failed (services deployed fine): %s%s\n' "$YELLOW" "$edge_sync_output" "$RESET"
fi

echo ""
summary_msg=""
if [ "$UNHEALTHY_COUNT" -gt 0 ]; then
  summary_msg="${GREEN}${PASS} passed${RESET}  ${YELLOW}${UNHEALTHY_COUNT} unhealthy${RESET}  ${RED}${FAILED} failed${RESET}  ${DIM}${SKIPPED} skipped${RESET}"
else
  summary_msg="${GREEN}${PASS} passed${RESET}  ${RED}${FAILED} failed${RESET}  ${DIM}${SKIPPED} skipped${RESET}"
fi
printf '  %b\n' "$summary_msg"
printf '  %sTotal: %dm %02ds%s\n' "$DIM" "$((TOTAL / 60))" "$((TOTAL % 60))" "$RESET"
printf '  %s%s%s\n' "$DIM" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$RESET"
echo ""
if [ "$UNHEALTHY_COUNT" -gt 0 ]; then
  printf '  %s%s⚠  WARNING: Some services were deployed successfully but failed their health checks!%s\n' "$YELLOW" "$BOLD" "$RESET"
  echo ""
fi
rule "$MAGENTA"

# Non-zero exit if anything failed
[ "$FAILED" -eq 0 ]
