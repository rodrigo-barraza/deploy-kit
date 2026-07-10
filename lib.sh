#!/bin/bash
# ============================================================
# Deploy Kit — Shared Library
#
# Source this file from a per-service deploy.sh after setting:
#
#   IMAGE_NAME       (required)  e.g. "prism-service"
#   DISPLAY_NAME     (optional)  e.g. "🔷 Prism Service"     — defaults to IMAGE_NAME
#   BUILD_ARGS       (optional)  extra --build-arg flags
#   BUILD_SECRETS    (optional)  extra --secret flags (BuildKit)
#   BUILD_EXTRA_FLAGS(optional)  e.g. "--network=host"
#   BUILD_TAIL_LINES (optional)  lines of build output to show (default: 5)
#   SKIP_ENV_DEPLOY  (optional)  set "true" to skip .env.deploy validation
#
# Hook functions (define before sourcing):
#   EXTRA_VALIDATE()   — additional file checks
#   PRE_BUILD()        — runs before docker build (set BUILD_ARGS here)
#   EXTRA_SSH_SYNC()   — sync extra files during SSH deploy
#   EXTRA_SMB_SYNC()   — sync extra files during SMB fallback
#
# Modes:
#   (default)          — full pipeline: validate → pull → build → deploy
#   --build-only       — validate → pull → build (no deploy)
#   --deploy-only      — deploy only (skip validate/pull/build)
#   --transfer-only    — transfer image to target (no restart)
#   --restart-only     — restart container on target (no transfer)
#
# Usage:
#   npm run deploy              # full deploy
#   npm run deploy -- --dry-run # validate without deploying
#   npm run deploy -- --skip-pull
#   npm run deploy -- --no-cache
# ============================================================

# ── Guard ─────────────────────────────────────────────────────
if [ -z "${IMAGE_NAME:-}" ]; then
  echo "ERROR: IMAGE_NAME must be set before sourcing lib.sh" >&2
  exit 1
fi
if [ -z "${SCRIPT_DIR:-}" ]; then
  echo "ERROR: SCRIPT_DIR must be set before sourcing lib.sh" >&2
  exit 1
fi

# ── Defaults ──────────────────────────────────────────────────
DISPLAY_NAME="${DISPLAY_NAME:-$IMAGE_NAME}"
BUILD_ARGS="${BUILD_ARGS:-}"
BUILD_SECRETS="${BUILD_SECRETS:-}"
BUILD_EXTRA_FLAGS="${BUILD_EXTRA_FLAGS:-}"
BUILD_TAIL_LINES="${BUILD_TAIL_LINES:-5}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
SKIP_ENV_DEPLOY="${SKIP_ENV_DEPLOY:-false}"

# ── SSH agent (for --ssh default in docker build) ─────────────
# BuildKit forwards the host SSH agent into RUN --mount=type=ssh
# layers so pnpm/git can authenticate to private GitHub repos.
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  ssh_status=0
  ssh-add -l >/dev/null 2>&1 || ssh_status=$?
  if [ $ssh_status -eq 2 ]; then
    unset SSH_AUTH_SOCK
  fi
fi

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  eval "$(ssh-agent -s)" > /dev/null 2>&1
  _STARTED_SSH_AGENT=true
fi
if ! ssh-add -l > /dev/null 2>&1; then
  ssh-add 2> /dev/null || true
fi

# ── BuildKit (default driver) ─────────────────────────────────
# Docker 23+ embeds BuildKit directly in dockerd. The default
# `docker` driver supports all BuildKit features (--ssh, --mount,
# multi-stage, --secret) without a separate sidecar container.
# This avoids the daemon saturation and silent hangs caused by
# the docker-container driver under heavy parallel builds.

# ── Compression ───────────────────────────────────────────────
# Prefer pigz (parallel gzip) for 3-5x faster image compression
if command -v pigz &>/dev/null; then
  GZIP_CMD="pigz"
else
  GZIP_CMD="gzip"
fi

# ── Deploy target (set by deploy-all.sh from projects.json) ───
# Falls back to legacy defaults (Synology NAS) when run standalone.
DEPLOY_METHOD="${DEPLOY_METHOD:-ssh}"                 # ssh | docker-api
DEPLOY_TARGET="${DEPLOY_TARGET:-synology}"            # device ID
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-}"                # target IP
DEPLOY_SSH_HOST="${DEPLOY_SSH_HOST:-nas}"             # SSH config alias
DEPLOY_DOCKER_BIN="${DEPLOY_DOCKER_BIN:-/usr/local/bin/docker}"
DEPLOY_DOCKER_API="${DEPLOY_DOCKER_API:-}"            # tcp://host:port
DEPLOY_COMPOSE_ROOT="${DEPLOY_COMPOSE_ROOT:-/volume1/docker}"
DEPLOY_SMB_ROOT="${DEPLOY_SMB_ROOT:-/mnt/k}"

# Derived paths (SSH method only)
DEPLOY_COMPOSE_DIR="${DEPLOY_COMPOSE_ROOT}/${IMAGE_NAME}"
DEPLOY_SMB_DIR="${DEPLOY_SMB_ROOT}/${IMAGE_NAME}"

# ── Flags ─────────────────────────────────────────────────────
DRY_RUN=false
SKIP_PULL=false
NO_CACHE=""
BUILD_ONLY=false
DEPLOY_ONLY=false
TRANSFER_ONLY=false
RESTART_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --skip-pull)      SKIP_PULL=true ;;
    --no-cache)       NO_CACHE="--no-cache" ;;
    --build-only)     BUILD_ONLY=true ;;
    --deploy-only)    DEPLOY_ONLY=true ;;
    --transfer-only)  TRANSFER_ONLY=true ;;
    --restart-only)   RESTART_ONLY=true ;;
  esac
done

# --transfer-only and --restart-only are sub-modes of deploy
# (they skip the build phase just like --deploy-only)
if $TRANSFER_ONLY || $RESTART_ONLY; then
  DEPLOY_ONLY=true
fi

# ── Colors & logging (shared) ─────────────────────────────────
DEPLOY_KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DEPLOY_KIT_DIR}/colors.sh"

# Override fail() to also exit (lib.sh is fatal on failure)
fail()  { printf '%s   %s✖ %s%s\n' "$(ts)" "$RED" "$1" "$RESET"; exit 1; }

# ── Timer ─────────────────────────────────────────────────────
DEPLOY_START=$SECONDS

# ── Header ────────────────────────────────────────────────────
echo ""
printf '%s%s══════════════════════════════════════════════════════%s\n' "$CYAN" "$BOLD" "$RESET"
if $BUILD_ONLY; then
  printf '%s%s  %s — Build%s\n' "$CYAN" "$BOLD" "$DISPLAY_NAME" "$RESET"
elif $TRANSFER_ONLY; then
  printf '%s%s  %s — Transfer to %s%s\n' "$CYAN" "$BOLD" "$DISPLAY_NAME" "$DEPLOY_TARGET" "$RESET"
elif $RESTART_ONLY; then
  printf '%s%s  %s — Restart on %s%s\n' "$CYAN" "$BOLD" "$DISPLAY_NAME" "$DEPLOY_TARGET" "$RESET"
elif $DEPLOY_ONLY; then
  printf '%s%s  %s — Deploy to %s%s\n' "$CYAN" "$BOLD" "$DISPLAY_NAME" "$DEPLOY_TARGET" "$RESET"
else
  printf '%s%s  %s — Build & Deploy to %s%s\n' "$CYAN" "$BOLD" "$DISPLAY_NAME" "$DEPLOY_TARGET" "$RESET"
fi
if $DRY_RUN; then
  printf '%s%s  ⚠  DRY RUN — no changes will be made%s\n' "$YELLOW" "$BOLD" "$RESET"
fi
printf '%s%s══════════════════════════════════════════════════════%s\n' "$CYAN" "$BOLD" "$RESET"

# ══════════════════════════════════════════════════════════════
# BUILD PHASE (validate → pull → build)
# Runs for: default mode and --build-only
# ══════════════════════════════════════════════════════════════
if ! $DEPLOY_ONLY; then

  # ── Validate required files ──────────────────────────────────
  step "Validating deployment files"

  DEPLOY_ENV="${DEPLOY_KIT_DIR}/.env.deploy"
  if [ "$SKIP_ENV_DEPLOY" != "true" ]; then
    if [ ! -f "$DEPLOY_ENV" ]; then
      fail ".env.deploy not found at ${DEPLOY_ENV} — create from .env.deploy.example in deploy-kit/"
    fi
    ok ".env.deploy found ($(wc -l < "$DEPLOY_ENV") lines)"
  fi

  # Call optional extra validation hook
  if type EXTRA_VALIDATE &>/dev/null; then
    EXTRA_VALIDATE
  fi

  # ── Git info ──────────────────────────────────────────────────
  cd "$SCRIPT_DIR"
  GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  info "Branch: ${GIT_BRANCH} @ ${GIT_SHA}"
  info "Time:   ${BUILD_TIME}"

  # ── 1. Pull latest ──────────────────────────────────────────
  if ! $SKIP_PULL; then
    step "Pulling latest changes"
    if $DRY_RUN; then
      info "(skipped — dry run)"
    else
      git pull --ff-only 2>&1 | sed 's/^/  /'
      GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
      ok "Now at ${GIT_SHA}"
    fi
  else
    info "Skipping git pull (--skip-pull)"
  fi

  # ── 1.5 Lockfile sync ──────────────────────────────────────
  # Ensure pnpm-lock.yaml and node_modules are in sync with
  # package.json. Git-based dependencies (github:...) are
  # pinned by SHA in the lockfile — `pnpm install` alone won't
  # re-resolve them. We first run `pnpm update` on any git deps
  # to pull the latest commit, then a full install to reconcile.
  # If the lockfile changed, auto-commit it so drift doesn't
  # recur on the next deploy.
  if [ -f "pnpm-lock.yaml" ] && ! $DRY_RUN; then
    needs_sync=false

    if [ ! -d "node_modules" ]; then
      needs_sync=true
      info "node_modules not found — syncing dependencies..."
    else
      last_built_sha=$(docker inspect --format '{{index .Config.Labels "git.sha"}}' "${IMAGE_NAME}:latest" 2>/dev/null || echo "")
      if [ -n "$last_built_sha" ]; then
        if ! git diff --quiet "$last_built_sha" HEAD -- package.json pnpm-lock.yaml 2>/dev/null; then
          needs_sync=true
          info "package.json or pnpm-lock.yaml modified since last build — syncing..."
        fi
      else
        needs_sync=true
        info "No previous build image found — syncing..."
      fi

      if [ "${ANY_LIB_CHANGED:-false}" = "true" ]; then
        needs_sync=true
        info "Upstream libraries updated in Phase 0 — syncing..."
      fi

      if ! $needs_sync; then
        stale_workspace_libs=$(node "${DEPLOY_KIT_DIR}/scripts/check-stale-locks.js" 2>/dev/null || true)
        if [ -n "$stale_workspace_libs" ]; then
          needs_sync=true
          info "Stale workspace library locks detected (${stale_workspace_libs}) — syncing..."
        fi
      fi
    fi

    if $needs_sync; then
      step "Syncing dependencies"

      # Force re-resolve git-based deps (lockfile pins stale SHAs)
      GIT_DEPS=$(node -e "
        const p = require('./package.json');
        const all = { ...p.dependencies, ...p.devDependencies };
        const git = Object.keys(all).filter(k => /^(git\+|github:)/.test(all[k]));
        if (git.length) console.log(git.join(' '));
      " 2>/dev/null || true)
      if [ -n "$GIT_DEPS" ]; then
        info "Updating git deps: ${GIT_DEPS}"
        pnpm update $GIT_DEPS 2>&1 | tail -3 | sed 's/^/  /'
      fi

      pnpm install --ignore-scripts 2>&1 | tail -3 | sed 's/^/  /'

      # Auto-approve any git-hosted deps whose commit SHAs changed.
      # pnpm 11 requires explicit allowBuilds entries with full URLs
      # for git deps — approve-builds --all handles this automatically.
      pnpm approve-builds --all 2>/dev/null || true

      # No URL rewriting needed — Docker build uses --ssh default
      # to forward the host SSH agent for private git deps.

      if ! git diff --quiet pnpm-lock.yaml pnpm-workspace.yaml 2>/dev/null; then
        step "Lockfile out of sync — auto-committing"
        git add pnpm-lock.yaml pnpm-workspace.yaml
        git commit -m "chore: sync pnpm-lock.yaml

Auto-committed by deploy-kit — lockfile or allowBuilds was out of
sync with package.json, which causes pnpm install failures in Docker." 2>&1 | sed 's/^/  /'
        git push 2>&1 | sed 's/^/  /' || warn "Auto-push failed — lockfile committed locally only"
        # Re-capture SHA after the auto-commit
        GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        ok "Lockfile committed and pushed (now at ${GIT_SHA})"
      else
        ok "Dependencies up to date"
      fi
    else
      info "Dependencies up to date (skipped host sync)"
    fi
  fi

  # ── 1.6 Run Tests ───────────────────────────────────────────
  if grep -q '"test":' package.json 2>/dev/null; then
    # Call optional pre-test hook (e.g. to run a host build if tests depend on dist/)
    if type PRE_TEST &>/dev/null; then
      PRE_TEST
    fi

    step "Running Tests"
    if $DRY_RUN; then
      info "(skipped — dry run)"
    else
      TEST_START=$SECONDS

      if grep -Eq '"test":.*(vitest|jest)' package.json 2>/dev/null; then
        # ── Resource calculation ──────────────────────────────
        _test_total_cores=$(nproc 2>/dev/null || echo 4)
        _test_concurrent_builds="${MAX_CONCURRENT_BUILDS:-1}"
        [ "$_test_concurrent_builds" -lt 1 ] 2>/dev/null && _test_concurrent_builds=1

        # Cores available to this service (share fairly across concurrent builds)
        _test_available_cores=$(( _test_total_cores / _test_concurrent_builds ))
        [ "$_test_available_cores" -lt 2 ] && _test_available_cores=2

        # Count test files to decide if sharding is worthwhile
        _test_file_count=$(find src tests -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' 2>/dev/null \
          | grep -v node_modules | grep -v '/live/' | wc -l)

        # ── Sharding: split into N parallel Vitest instances ──
        # Sharding pays off when there are enough files to distribute
        # and enough cores to run multiple instances without contention.
        # Formula: shards = available_cores / 8, clamped to [1, 4]
        # Each shard gets workers = available_cores / shards
        _test_shard_count=1
        if [ "$_test_file_count" -ge 40 ] && [ "$_test_available_cores" -ge 8 ]; then
          _test_shard_count=$(( _test_available_cores / 8 ))
          [ "$_test_shard_count" -lt 1 ] && _test_shard_count=1
          [ "$_test_shard_count" -gt 4 ] && _test_shard_count=4
        fi

        _test_workers_per_shard=$(( _test_available_cores / _test_shard_count ))
        [ "$_test_workers_per_shard" -lt 2 ] && _test_workers_per_shard=2

        if [ "$_test_shard_count" -gt 1 ]; then
          # ── Parallel sharded execution ────────────────────
          info "Sharding ${_test_file_count} test files across ${_test_shard_count} shards × ${_test_workers_per_shard} workers (Cores: ${_test_total_cores}, Concurrency: ${_test_concurrent_builds})"

          _shard_log_dir="${DEPLOY_LOG_DIR:-.deploy-logs}/shards"
          mkdir -p "$_shard_log_dir"
          _shard_pids=()
          _shard_failed=0

          for _shard_index in $(seq 1 "$_test_shard_count"); do
            _shard_log="${_shard_log_dir}/${IMAGE_NAME:-tests}_shard${_shard_index}.log"
            (
              export CI=true
              pnpm test \
                --reporter=dot \
                --shard="${_shard_index}/${_test_shard_count}" \
                --maxWorkers="${_test_workers_per_shard}" \
                > "$_shard_log" 2>&1
            ) &
            _shard_pids+=($!)
          done

          # Wait for all shards and collect exit codes
          for _pid_index in "${!_shard_pids[@]}"; do
            if ! wait "${_shard_pids[$_pid_index]}"; then
              _shard_failed=1
              _failed_shard_index=$(( _pid_index + 1 ))
              warn "Shard ${_failed_shard_index}/${_test_shard_count} failed"
              _failed_log="${_shard_log_dir}/${IMAGE_NAME:-tests}_shard${_failed_shard_index}.log"
              if [ -f "$_failed_log" ]; then
                printf '%s\n' "  ── Shard ${_failed_shard_index} output ──"
                sed 's/^/  /' "$_failed_log" | tail -40
              fi
            fi
          done

          if [ "$_shard_failed" -eq 1 ]; then
            fail "Tests failed! Aborting deployment. (shard logs: ${_shard_log_dir}/)"
          fi
        else
          # ── Single-process execution (small suites / few cores) ──
          info "Running ${_test_file_count} test files with ${_test_workers_per_shard} workers (Cores: ${_test_total_cores}, Concurrency: ${_test_concurrent_builds})"
          if ! (set -o pipefail; export CI=true; pnpm run test -- --maxWorkers="${_test_workers_per_shard}" 2>&1 | sed 's/^/  /'); then
            fail "Tests failed! Aborting deployment."
          fi
        fi
      else
        # Non-vitest/jest runner — run as-is
        if ! (set -o pipefail; export CI=true; pnpm run test 2>&1 | sed 's/^/  /'); then
          fail "Tests failed! Aborting deployment."
        fi
      fi

      ok "Tests passed in $((SECONDS - TEST_START))s"
    fi
  fi

  # ── 2. Build image ──────────────────────────────────────────
  TAG_LATEST="${IMAGE_NAME}:latest"
  TAG_SHA="${IMAGE_NAME}:${GIT_SHA}"

  # Call optional pre-build hook (sets BUILD_ARGS, etc.)
  if type PRE_BUILD &>/dev/null; then
    PRE_BUILD
  fi

  step "Building Docker image"
  info "Tags: ${TAG_LATEST}, ${TAG_SHA}"

  if $DRY_RUN; then
    info "(skipped — dry run)"
  else
    BUILD_START_INNER=$SECONDS
    temp_log=$(mktemp "/tmp/docker-build-${IMAGE_NAME}-XXXXXX.log")
    
    # Start a background progress ticker to reassure the user (loops only while parent process $$ is alive)
    elapsed=0
    (
      while kill -0 "$$" 2>/dev/null; do
        sleep 10
        elapsed=$((elapsed + 10))
        echo "  Still building... (${elapsed}s elapsed)"
      done
    ) &
    ticker_pid=$!

    set +e
    timeout --kill-after=30 "${BUILD_TIMEOUT}" \
      docker buildx build \
      --load \
      --ssh default \
      $NO_CACHE \
      $BUILD_EXTRA_FLAGS \
      $BUILD_ARGS \
      $BUILD_SECRETS \
      --label "git.sha=${GIT_SHA}" \
      --label "git.branch=${GIT_BRANCH}" \
      --label "build.time=${BUILD_TIME}" \
      -t "$TAG_LATEST" \
      -t "$TAG_SHA" \
      . > "$temp_log" 2>&1
    BUILD_EXIT=$?
    set -e

    # Stop the background progress ticker
    kill "$ticker_pid" 2>/dev/null || true
    wait "$ticker_pid" 2>/dev/null || true

    # If the build failed, dump the tail of the temp log to stdout for quick terminal debugging
    if [ "$BUILD_EXIT" -ne 0 ]; then
      echo "  [ERROR] Build output (last ${BUILD_TAIL_LINES} lines):"
      tail -n "${BUILD_TAIL_LINES}" "$temp_log" | sed 's/^/  /'
    fi

    # Append the full build log to the caller's log file (dynamic scoped $log_file from deploy-all.sh)
    if [ -n "${log_file:-}" ]; then
      cat "$temp_log" >> "$log_file"
    fi
    
    rm -f "$temp_log"

    if [ "$BUILD_EXIT" -ne 0 ]; then
      if [ "$BUILD_EXIT" -eq 124 ] || [ "$BUILD_EXIT" -eq 137 ]; then
        fail "Build timed out after ${BUILD_TIMEOUT}s"
      else
        fail "Build failed (exit ${BUILD_EXIT}) in $((SECONDS - BUILD_START_INNER))s"
      fi
      exit 1
    fi
    ok "Built in $((SECONDS - BUILD_START_INNER))s"
  fi

  # ── If build-only, stop here ─────────────────────────────────
  if $BUILD_ONLY; then
    # Clean up local SHA-tagged image (keep :latest for --changed-only)
    if ! $DRY_RUN && [ "${GIT_SHA:-}" != "unknown" ] && [ -n "${GIT_SHA:-}" ]; then
      docker rmi "$TAG_SHA" 2>/dev/null && info "Removed local tag ${TAG_SHA}" || true
      docker image prune -f 2>/dev/null | grep -v 'Total reclaimed space: 0B' | sed 's/^/  /' || true
    fi
    TOTAL=$((SECONDS - DEPLOY_START))
    echo ""
    printf '%s%s══════════════════════════════════════════════════════%s\n' "$GREEN" "$BOLD" "$RESET"
    printf '%s%s  ✅ Build complete in %ss%s\n' "$GREEN" "$BOLD" "$TOTAL" "$RESET"
    cd "$SCRIPT_DIR"
    GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '  %s%s@%s (%s)%s\n' "$DIM" "$GIT_BRANCH" "$GIT_SHA" "$BUILD_TIME" "$RESET"
    printf '%s%s══════════════════════════════════════════════════════%s\n' "$GREEN" "$BOLD" "$RESET"
    echo ""
    exit 0
  fi
fi

# ══════════════════════════════════════════════════════════════
# DEPLOY PHASE (multi-device: SSH or Docker API)
# Runs for: default mode and --deploy-only
# ══════════════════════════════════════════════════════════════

# When deploy-only, we need git info for the summary but skip the build
if $DEPLOY_ONLY; then
  cd "$SCRIPT_DIR"
  GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TAG_LATEST="${IMAGE_NAME}:latest"
  DEPLOY_ENV="${DEPLOY_KIT_DIR}/.env.deploy"
fi

# ── Shared: verify container is running after restart ─────────
verify_container() {
  local check_cmd="$1"  # command prefix to run docker ps
  HEALTH_MAX=10
  HEALTH_INTERVAL=2
  HEALTH_OK=false
  for _h in $(seq 1 $HEALTH_MAX); do
    sleep $HEALTH_INTERVAL
    CONTAINER_STATUS=$($check_cmd ps --filter "name=${IMAGE_NAME}$" --format '{{.Status}}' 2>/dev/null || echo "")
    if [ -z "$CONTAINER_STATUS" ]; then
      fail "Container '${IMAGE_NAME}' not found after restart — deploy failed"
    fi
    if echo "$CONTAINER_STATUS" | grep -qiE '^Up'; then
      HEALTH_OK=true
      break
    fi
    if [ "$_h" -lt "$HEALTH_MAX" ]; then
      info "Container not ready yet (${CONTAINER_STATUS}) — retrying in ${HEALTH_INTERVAL}s... (${_h}/${HEALTH_MAX})"
    fi
  done
  if ! $HEALTH_OK; then
    fail "Container '${IMAGE_NAME}' is not running after ${HEALTH_MAX} checks (status: ${CONTAINER_STATUS})"
  fi
  ok "Container running (${CONTAINER_STATUS})"
}

# ══════════════════════════════════════════════════════════════
# METHOD: docker-api  — pipe image + compose via DOCKER_HOST
# ══════════════════════════════════════════════════════════════
deploy_docker_api() {
  local remote_host="$DEPLOY_DOCKER_API"

  if $DRY_RUN; then
    info "(skipped — dry run)"
    return 0
  fi

  # Verify connectivity
  if ! docker -H "$remote_host" info > /dev/null 2>&1; then
    fail "Cannot connect to Docker API at ${remote_host}"
  fi
  ok "Docker API at ${remote_host} reachable"

  # ── Transfer sub-phase ────────────────────────────────────────
  if ! $RESTART_ONLY; then
    step "Transferring image via Docker API → ${remote_host} (${DEPLOY_TARGET})"

    # Preserve previous image for rollback
    PREV_TAG="${IMAGE_NAME}:previous"
    HAS_CURRENT=$(docker -H "$remote_host" images "$TAG_LATEST" --format '{{.ID}}' 2>/dev/null || true)
    if [ -n "$HAS_CURRENT" ]; then
      info "Tagging current :latest as :previous for rollback..."
      docker -H "$remote_host" tag "$TAG_LATEST" "$PREV_TAG" 2>/dev/null || true
      ok "Rollback image saved as ${PREV_TAG}"
    fi

    # Transfer image
    TRANSFER_START=$SECONDS
    info "Piping image to remote Docker daemon..."
    set +e
    for _transfer_attempt in 1 2 3; do
      TRANSFER_OUTPUT=$( (set -o pipefail; docker save "$TAG_LATEST" | $GZIP_CMD | docker -H "$remote_host" load) 2>&1 )
      TRANSFER_EXIT=$?
      if [ "$TRANSFER_EXIT" -eq 0 ]; then
        break
      fi
      if [ "$_transfer_attempt" -lt 3 ]; then
        _jitter=$(( (RANDOM % 5) + 3 ))
        warn "Transfer failed (exit ${TRANSFER_EXIT}) — retrying in ${_jitter}s..."
        sleep "$_jitter"
      fi
    done
    set -e
    if [ "$TRANSFER_EXIT" -ne 0 ]; then
      echo "$TRANSFER_OUTPUT" | sed 's/^/  /'
      fail "Image transfer failed (exit ${TRANSFER_EXIT})"
    fi
    ok "Image transferred in $((SECONDS - TRANSFER_START))s"
  fi

  # ── Restart sub-phase ─────────────────────────────────────────
  if ! $TRANSFER_ONLY; then
    step "Restarting container via Docker API → ${remote_host}"

    # Stage .env next to docker-compose.yml so env_file: .env resolves
    local staged_env=false
    if [ "$SKIP_ENV_DEPLOY" != "true" ] && [ -f "$DEPLOY_ENV" ]; then
      # Back up existing .env if present (don't clobber local dev config)
      [ -f "${SCRIPT_DIR}/.env" ] && cp "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/.env.pre-deploy"
      cp "$DEPLOY_ENV" "${SCRIPT_DIR}/.env"
      staged_env=true
      ok ".env staged for compose"
    fi

    # Build compose file flags — stack device-specific override if present
    local compose_files="-f ${SCRIPT_DIR}/docker-compose.yml"
    local override_file="${SCRIPT_DIR}/docker-compose.${DEPLOY_TARGET}.yml"
    if [ -f "$override_file" ]; then
      compose_files="$compose_files -f $override_file"
      info "Using device override: docker-compose.${DEPLOY_TARGET}.yml"
    fi

    # Restart container via local compose targeting remote daemon
    info "Restarting container..."
    set +e
    COMPOSE_OUTPUT=$(DOCKER_HOST="$remote_host" docker compose \
      $compose_files \
      down --remove-orphans 2>&1)
    COMPOSE_OUTPUT+=$'\n'
    COMPOSE_OUTPUT+=$(DOCKER_HOST="$remote_host" docker compose \
      $compose_files \
      up -d 2>&1)
    COMPOSE_EXIT=$?
    set -e

    echo "$COMPOSE_OUTPUT" | sed 's/^/ /'

    # Restore original .env
    if $staged_env; then
      if [ -f "${SCRIPT_DIR}/.env.pre-deploy" ]; then
        mv "${SCRIPT_DIR}/.env.pre-deploy" "${SCRIPT_DIR}/.env"
      else
        rm -f "${SCRIPT_DIR}/.env"
      fi
    fi

    if echo "$COMPOSE_OUTPUT" | grep -qiE 'could not find an available.*address pool|port is already allocated|driver failed programming'; then
      fail "Container failed to start — Docker infrastructure error detected"
    fi
    if [ "$COMPOSE_EXIT" -ne 0 ]; then
      fail "Container restart failed (exit ${COMPOSE_EXIT})"
    fi

    # Verify container running
    verify_container "docker -H $remote_host"

    # Prune old images on remote (keep :latest and :previous for rollback)
    info "Pruning old images on ${DEPLOY_TARGET}..."
    docker -H "$remote_host" images "${IMAGE_NAME}" --format '{{.Tag}} {{.ID}}' \
      | grep -vE '^(latest|previous) ' \
      | awk '{print $2}' \
      | xargs -r docker -H "$remote_host" rmi 2>/dev/null || true
    docker -H "$remote_host" image prune -f 2>/dev/null | sed 's/^/  /' || true

    # ── Clean up local build images ───────────────────────────────
    # Keep only :latest (needed for --changed-only SHA label detection).
    # Remove the SHA-tagged image and prune dangling layers.
    step "Cleaning up local build images"
    if [ "${GIT_SHA:-}" != "unknown" ] && [ -n "${GIT_SHA:-}" ]; then
      docker rmi "$TAG_SHA" 2>/dev/null && info "Removed local tag ${TAG_SHA}" || true
    fi
    docker image prune -f 2>/dev/null | grep -v 'Total reclaimed space: 0B' | sed 's/^/  /' || true
  fi
}

# ══════════════════════════════════════════════════════════════
# METHOD: ssh  — pipe image + copy files + restart over SSH
# ══════════════════════════════════════════════════════════════
deploy_ssh() {
  # Detect SSH access (retry with jittered backoff for parallel tiers)
  HAS_SSH=false
  for _ssh_attempt in 1 2; do
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$DEPLOY_SSH_HOST" "true" 2>/dev/null; then
      HAS_SSH=true
      ok "SSH access to ${DEPLOY_SSH_HOST} confirmed"
      break
    fi
    if [ "$_ssh_attempt" -eq 1 ]; then
      _jitter=$(( (RANDOM % 4) + 2 ))
      info "SSH probe failed — retrying in ${_jitter}s..."
      sleep "$_jitter"
    fi
  done

  if $HAS_SSH; then

    if $DRY_RUN; then
      info "(skipped — dry run)"
      return 0
    fi

    # ── Transfer sub-phase ────────────────────────────────────────
    if ! $RESTART_ONLY; then
      step "Transferring image via SSH → ${DEPLOY_SSH_HOST} (${DEPLOY_TARGET})"

      ssh "$DEPLOY_SSH_HOST" "mkdir -p '${DEPLOY_COMPOSE_DIR}' 2>/dev/null || sudo mkdir -p '${DEPLOY_COMPOSE_DIR}'"

      info "Syncing docker-compose.yml..."
      cat "${SCRIPT_DIR}/docker-compose.yml" | ssh "$DEPLOY_SSH_HOST" "cat > '${DEPLOY_COMPOSE_DIR}/docker-compose.yml'"

      # Sync device-specific compose override if present
      local override_file="${SCRIPT_DIR}/docker-compose.${DEPLOY_TARGET}.yml"
      if [ -f "$override_file" ]; then
        info "Syncing device override: docker-compose.${DEPLOY_TARGET}.yml..."
        cat "$override_file" | ssh "$DEPLOY_SSH_HOST" "cat > '${DEPLOY_COMPOSE_DIR}/docker-compose.${DEPLOY_TARGET}.yml'"
      fi

      if [ "$SKIP_ENV_DEPLOY" != "true" ] && [ -f "$DEPLOY_ENV" ]; then
        info "Syncing .env.deploy → .env..."
        cat "$DEPLOY_ENV" | ssh "$DEPLOY_SSH_HOST" "cat > '${DEPLOY_COMPOSE_DIR}/.env'"
        ok ".env synced"
      fi

      if type EXTRA_SSH_SYNC &>/dev/null; then
        EXTRA_SSH_SYNC
      fi

      # Preserve previous image for rollback
      PREV_TAG="${IMAGE_NAME}:previous"
      HAS_CURRENT=$(ssh "$DEPLOY_SSH_HOST" "sudo ${DEPLOY_DOCKER_BIN} images '${TAG_LATEST}' --format '{{.ID}}'" 2>/dev/null || true)
      if [ -n "$HAS_CURRENT" ]; then
        info "Tagging current :latest as :previous for rollback..."
        ssh "$DEPLOY_SSH_HOST" "sudo ${DEPLOY_DOCKER_BIN} tag '${TAG_LATEST}' '${PREV_TAG}'" 2>/dev/null || true
        ok "Rollback image saved as ${PREV_TAG}"
      fi

      TRANSFER_START=$SECONDS
      info "Piping image over SSH (this may take a moment)..."
      set +e
      for _transfer_attempt in 1 2 3; do
        TRANSFER_OUTPUT=$( (set -o pipefail; docker save "$TAG_LATEST" | $GZIP_CMD | ssh "$DEPLOY_SSH_HOST" "gunzip | sudo ${DEPLOY_DOCKER_BIN} load") 2>&1 )
        TRANSFER_EXIT=$?
        if [ "$TRANSFER_EXIT" -eq 0 ]; then
          break
        fi
        if [ "$_transfer_attempt" -lt 3 ]; then
          _jitter=$(( (RANDOM % 5) + 3 ))
          warn "Transfer failed (exit ${TRANSFER_EXIT}) — retrying in ${_jitter}s..."
          sleep "$_jitter"
        fi
      done
      set -e
      if [ "$TRANSFER_EXIT" -ne 0 ]; then
        echo "$TRANSFER_OUTPUT" | sed 's/^/  /'
        fail "Image transfer failed (exit ${TRANSFER_EXIT}) — check NAS Docker daemon health"
      fi
      ok "Image transferred in $((SECONDS - TRANSFER_START))s"
    fi

    # ── Restart sub-phase ─────────────────────────────────────────
    if ! $TRANSFER_ONLY; then
      step "Restarting container on ${DEPLOY_SSH_HOST}"

      # Build the compose command (need override detection even if transfer was separate)
      local remote_compose_cmd="compose -f docker-compose.yml"
      local override_file="${SCRIPT_DIR}/docker-compose.${DEPLOY_TARGET}.yml"
      if [ -f "$override_file" ]; then
        remote_compose_cmd="compose -f docker-compose.yml -f docker-compose.${DEPLOY_TARGET}.yml"
      fi

      info "Restarting container..."
      COMPOSE_OUTPUT=$(ssh "$DEPLOY_SSH_HOST" "cd '${DEPLOY_COMPOSE_DIR}' && sudo ${DEPLOY_DOCKER_BIN} ${remote_compose_cmd} down --remove-orphans 2>&1 && sudo ${DEPLOY_DOCKER_BIN} ${remote_compose_cmd} up -d 2>&1" 2>&1)
      COMPOSE_EXIT=$?
      echo "$COMPOSE_OUTPUT" | sed 's/^/ /'

      if echo "$COMPOSE_OUTPUT" | grep -qiE 'could not find an available.*address pool|port is already allocated|driver failed programming'; then
        fail "Container failed to start — Docker infrastructure error detected"
      fi
      if [ "$COMPOSE_EXIT" -ne 0 ]; then
        fail "Container restart failed (exit ${COMPOSE_EXIT})"
      fi

      verify_container "ssh $DEPLOY_SSH_HOST sudo ${DEPLOY_DOCKER_BIN}"

      info "Pruning old images on ${DEPLOY_TARGET} (keeping :previous for rollback)..."
      ssh "$DEPLOY_SSH_HOST" "sudo ${DEPLOY_DOCKER_BIN} images '${IMAGE_NAME}' --format '{{.Tag}} {{.ID}}' \
        | grep -vE '^(latest|previous) ' \
        | awk '{print \$2}' \
        | xargs -r sudo ${DEPLOY_DOCKER_BIN} rmi 2>/dev/null || true"
      ssh "$DEPLOY_SSH_HOST" "sudo ${DEPLOY_DOCKER_BIN} image prune -f" 2>/dev/null | sed 's/^/  /' || true

      # ── Clean up local build images ───────────────────────────────
      # Keep only :latest (needed for --changed-only SHA label detection).
      # Remove the SHA-tagged image and prune dangling layers.
      step "Cleaning up local build images"
      if [ "${GIT_SHA:-}" != "unknown" ] && [ -n "${GIT_SHA:-}" ]; then
        docker rmi "$TAG_SHA" 2>/dev/null && info "Removed local tag ${TAG_SHA}" || true
      fi
      docker image prune -f 2>/dev/null | grep -v 'Total reclaimed space: 0B' | sed 's/^/  /' || true
    fi

  else
    # ── SMB fallback ──────────────────────────────────────────
    warn "SSH to '${DEPLOY_SSH_HOST}' unavailable — falling back to SMB export"
    step "Exporting via SMB → ${DEPLOY_SMB_DIR}"

    if $DRY_RUN; then
      info "(skipped — dry run)"
      return 0
    fi

    TARBALL="${IMAGE_NAME}.tar.gz"
    info "Saving image..."
    docker save "$TAG_LATEST" | $GZIP_CMD > "/tmp/${TARBALL}"

    if ! mkdir -p "${DEPLOY_SMB_DIR}" 2>/dev/null; then
      rm -f "/tmp/${TARBALL}"
      printf '  %s✖ Cannot create %s — is SMB mounted? Check permissions.%s\n' "$RED" "$DEPLOY_SMB_DIR" "$RESET" >&2
      exit 1
    fi

    cp "/tmp/${TARBALL}" "${DEPLOY_SMB_DIR}/${TARBALL}" || { rm -f "/tmp/${TARBALL}"; fail "Failed to copy image tarball"; }
    cp "${SCRIPT_DIR}/docker-compose.yml" "${DEPLOY_SMB_DIR}/docker-compose.yml" || { rm -f "/tmp/${TARBALL}"; fail "Failed to copy docker-compose.yml"; }

    if [ "$SKIP_ENV_DEPLOY" != "true" ] && [ -f "$DEPLOY_ENV" ]; then
      cp "$DEPLOY_ENV" "${DEPLOY_SMB_DIR}/.env" || { rm -f "/tmp/${TARBALL}"; fail "Failed to copy .env"; }
    fi

    if type EXTRA_SMB_SYNC &>/dev/null; then
      EXTRA_SMB_SYNC
    fi

    rm -f "/tmp/${TARBALL}"
    ok "Image exported to ${DEPLOY_SMB_DIR}/${TARBALL}"
    echo ""
    warn "Manual steps required on ${DEPLOY_TARGET}:"
    info "  1. Load image: docker load < ${TARBALL}"
    info "  2. Restart:    docker compose up -d"
  fi
}

# ── 3. Dispatch to deploy method ──────────────────────────────
if [ "$DEPLOY_METHOD" = "docker-api" ]; then
  deploy_docker_api
else
  deploy_ssh
fi

# ── Summary ───────────────────────────────────────────────────
TOTAL=$((SECONDS - DEPLOY_START))
echo ""
printf '%s%s══════════════════════════════════════════════════════%s\n' "$GREEN" "$BOLD" "$RESET"
if $TRANSFER_ONLY; then
  printf '%s%s  ✅ Transfer complete in %ss%s\n' "$GREEN" "$BOLD" "$TOTAL" "$RESET"
elif $RESTART_ONLY; then
  printf '%s%s  ✅ Restart complete in %ss%s\n' "$GREEN" "$BOLD" "$TOTAL" "$RESET"
elif $DEPLOY_ONLY; then
  printf '%s%s  ✅ Deploy complete in %ss%s\n' "$GREEN" "$BOLD" "$TOTAL" "$RESET"
else
  printf '%s%s  ✅ Build & deploy complete in %ss%s\n' "$GREEN" "$BOLD" "$TOTAL" "$RESET"
fi
printf '  %s%s@%s → %s (%s)%s\n' "$DIM" "$GIT_BRANCH" "$GIT_SHA" "$DEPLOY_TARGET" "$BUILD_TIME" "$RESET"
printf '%s%s══════════════════════════════════════════════════════%s\n' "$GREEN" "$BOLD" "$RESET"
echo ""
