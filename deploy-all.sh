#!/bin/bash
# ============================================================
# Deploy All Services
#
# Deployment pipeline:
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
#   npm run deploy -- --skip-tests         # skip each repo's test suite (deploys UNTESTED code)
#   npm run deploy -- --no-cache           # rebuild images from scratch
#   npm run deploy -- --changed-only       # only build+deploy services with git changes
#   npm run deploy -- --changed-all        # changed services, ignoring the TEMPORARY_SKIP list
#   npm run deploy -- --ignore-temp-skip   # disable the TEMPORARY_SKIP list for this run
#   npm run deploy -- --skip-deps          # skip library synchronization and dependency change checks
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
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
  echo 'ERROR: deploy-all requires Bash 5.1 or newer (wait -n -p).' >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"
source "${SCRIPT_DIR}/scripts/runtime.sh"
die() { fail "$*"; exit 1; }
DRY_RUN=false SKIP_PULL=false NO_CACHE=false NO_PARALLEL=false CHANGED_ONLY=false
SKIP_DEPS=false NO_IMPACT=false BUILD_ONLY=false COMPACT_WSL=false IGNORE_TEMP_SKIP=false
ONLY='' SKIP_LIST='' GROUP=''
case "${SKIP_TESTS:-}" in 1|true|yes|on) SKIP_TESTS=true ;; *) SKIP_TESTS=false ;; esac
MAX_CONCURRENT_BUILDS=6
if grep -qi microsoft /proc/version 2>/dev/null; then MAX_CONCURRENT_BUILDS=4; fi
MAX_CONCURRENT_SSH="${MAX_CONCURRENT_SSH:-8}"
BUILD_PHASE_TIMEOUT="${BUILD_PHASE_TIMEOUT:-1800}"
TRANSFER_PHASE_TIMEOUT="${TRANSFER_PHASE_TIMEOUT:-600}"
RESTART_PHASE_TIMEOUT="${RESTART_PHASE_TIMEOUT:-180}"
REMOTE_TIMEOUT="${REMOTE_TIMEOUT:-30}"
HEALTH_GATE_TIMEOUT="${HEALTH_GATE_TIMEOUT:-60}"
HEALTH_GATE_INTERVAL="${HEALTH_GATE_INTERVAL:-3}"
BUILD_CACHE_KEEP_STORAGE="${BUILD_CACHE_KEEP_STORAGE:-20GB}"
BUILD_CACHE_MAX_AGE="${BUILD_CACHE_MAX_AGE:-}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;; --skip-pull) SKIP_PULL=true ;; --skip-tests) SKIP_TESTS=true ;;
    --no-cache) NO_CACHE=true ;; --no-parallel) NO_PARALLEL=true ;;
    --changed-only) CHANGED_ONLY=true ;; --changed-all) CHANGED_ONLY=true; IGNORE_TEMP_SKIP=true ;;
    --ignore-temp-skip) IGNORE_TEMP_SKIP=true ;; --skip-deps) SKIP_DEPS=true ;; --no-impact) NO_IMPACT=true ;;
    --build-only) BUILD_ONLY=true ;; --compact-wsl) COMPACT_WSL=true ;;
    --only=?*) ONLY="${arg#*=}" ;; --skip=?*) SKIP_LIST="${arg#*=}" ;;
    --group=?*) GROUP="${GROUP:+${GROUP},}${arg#*=}" ;;
    --clients) GROUP="${GROUP:+${GROUP},}client" ;; --services) GROUP="${GROUP:+${GROUP},}service" ;;
    --bots) GROUP="${GROUP:+${GROUP},}bot" ;; --vault) GROUP="${GROUP:+${GROUP},}vault" ;;
    --max-builds=*) MAX_CONCURRENT_BUILDS="${arg#*=}" ;;
    --help|-h) sed -n '17,44s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) die "Unknown or empty option: ${arg}. Use --help." ;;
  esac
done
positive_integer --max-builds "$MAX_CONCURRENT_BUILDS" 64
positive_integer MAX_CONCURRENT_SSH "$MAX_CONCURRENT_SSH" 64
for setting in BUILD_PHASE_TIMEOUT TRANSFER_PHASE_TIMEOUT RESTART_PHASE_TIMEOUT REMOTE_TIMEOUT HEALTH_GATE_TIMEOUT HEALTH_GATE_INTERVAL; do
  positive_integer "$setting" "${!setting}"
done
[[ "$BUILD_CACHE_KEEP_STORAGE" =~ ^[1-9][0-9]*(B|KB|MB|GB|TB)$ ]] || die 'Invalid BUILD_CACHE_KEEP_STORAGE (example: 20GB)'
[[ -z "$BUILD_CACHE_MAX_AGE" || "$BUILD_CACHE_MAX_AGE" =~ ^[1-9][0-9]*(h|m|s)$ ]] || die 'Invalid BUILD_CACHE_MAX_AGE (example: 168h)'
if $NO_PARALLEL; then MAX_CONCURRENT_BUILDS=1; MAX_CONCURRENT_SSH=1; fi
export MAX_CONCURRENT_BUILDS
export DEPLOY_SKIP_DEPS="$SKIP_DEPS"
for command in node git flock timeout setsid; do command -v "$command" >/dev/null || die "Required command not found: $command"; done
deploy_paths "$SCRIPT_DIR"
PROJECTS_JSON="${PROJECTS_JSON_PATH:-${ROOT_DIR}/vault-service/projects.json}"
export PROJECTS_JSON_PATH="$PROJECTS_JSON"
[ -f "$PROJECTS_JSON" ] || die "projects.json not found: $PROJECTS_JSON"
STATE_HELPER="${SCRIPT_DIR}/scripts/deploy-state.js"
STATE_MODE=deployed
$BUILD_ONLY && STATE_MODE=built
DEPLOY_STATE_DIR="${DEPLOY_STATE_ROOT}/${STATE_MODE}"
declare -A TIER_SERVICES=() SVC_HEALTH_URL=() SVC_DEPLOY_TARGET=() SVC_LIB_DEPS=() SVC_DEPS=()
declare -A DEVICE_METHOD=() DEVICE_HOSTNAME=() DEVICE_ARCH=() DEVICE_SSH_ALIAS=() DEVICE_DOCKER_BIN=()
declare -A DEVICE_DOCKER_API=() DEVICE_COMPOSE_ROOT=() DEVICE_SMB_ROOT=()
ALL_SERVICES=() LIBRARY_IDS=() DOCKER_DEVICES=()
load_projects() {
  local data tier id
  TIER_SERVICES=(); SVC_HEALTH_URL=(); SVC_DEPLOY_TARGET=(); SVC_LIB_DEPS=(); SVC_DEPS=()
  DEVICE_METHOD=(); DEVICE_HOSTNAME=(); DEVICE_ARCH=(); DEVICE_SSH_ALIAS=(); DEVICE_DOCKER_BIN=()
  DEVICE_DOCKER_API=(); DEVICE_COMPOSE_ROOT=(); DEVICE_SMB_ROOT=(); ALL_SERVICES=()
  data=$(node "${SCRIPT_DIR}/scripts/parse-projects.js" "$PROJECTS_JSON" "$ROOT_DIR") || die 'Invalid project registry'
  eval "$data"
  for ((tier=0; tier<=MAX_TIER; tier++)); do
    for id in ${TIER_SERVICES[$tier]:-}; do ALL_SERVICES+=("$id"); done
  done
}
TEMPORARY_SKIP="qbittorrent-service,accounts-service,accounts-client,animals-service,animals-client,clankerbox-service,clankerbox-client,clock-crew-service,clock-crew-client,classic-whitemane-client,dygest-service,dygest-client,games-service,gauge-service,gauge-client,images-service,images-client,iron-service,iron-client,ledger-service,ledger-client,lights-client,lupos-client,meepothegeomancer-client,messages-service,messages-client,music-service,music-client,notes-service,notes-client,reels-service,reels-client,payments-service,payments-client"
declare -A PHASE_STATUS=()
declare -A SVC_SELECTED=() SVC_COLORS=() SVC_SHARED=() SVC_CHANGED=() NEEDS_BUILD=()
validate_list() {
  local name="$1" list="$2" item
  [ -n "$list" ] || return 0
  [[ "$list" != ,* && "$list" != *, && "$list" != *,,* ]] || die "Empty item in ${name}: $list"
  local items=(); IFS=, read -ra items <<< "$list"
  for item in "${items[@]}"; do
    if [ "$name" = group ]; then
      case "$item" in client|service|bot|vault) ;; *) die "Unknown group: $item" ;; esac
    else
      [ -n "${SVC_DEPLOY_TARGET[$item]:-}" ] || die "Unknown service in --${name}: $item"
    fi
  done
}
select_services() {
  validate_list only "$ONLY"; validate_list skip "$SKIP_LIST"; validate_list group "$GROUP"
  local svc cat group match count=0
  local groups=(); IFS=, read -ra groups <<< "$GROUP"
  for svc in "${ALL_SERVICES[@]}"; do
    SVC_SELECTED[$svc]=0
    [[ ",$SKIP_LIST," == *",$svc,"* ]] && continue
    if [ -n "$ONLY" ]; then
      [[ ",$ONLY," == *",$svc,"* ]] || continue
    elif ! $IGNORE_TEMP_SKIP && [[ ",$TEMPORARY_SKIP," == *",$svc,"* ]]; then continue
    fi
    if [ -n "$GROUP" ]; then
      cat=$(svc_category "$svc"); match=false
      for group in "${groups[@]}"; do
        case "$group" in
          vault) [ "$svc" != vault-service ] || match=true ;;
          service) { [ "$cat" != service ] || [ "$svc" = vault-service ]; } || match=true ;;
          *) [ "$cat" != "$group" ] || match=true ;;
        esac
      done
      $match || continue
    fi
    SVC_SELECTED[$svc]=1; count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die 'No services selected; check --only, --skip, and groups.'
}
should_deploy() { [ "${SVC_SELECTED[$1]:-0}" = 1 ]; }
load_projects
select_services
acquire_deploy_lock
DEPLOY_START=$SECONDS
INTERRUPTED=false DEPLOY_STARTED_AGENT=false
LOG_DIR=''
MAIN_COMMAND_PID=''
declare -A JOB_SERVICE=() JOB_PHASE=() MIGRATION_STOPPED=() MIGRATION_SOURCES=()
declare -A DEVICE_CONTAINERS=() DEVICE_REACHABLE=() IMPACT_VERDICT=() IMPACT_REASON=()
IMPACT_SCRIPT_OK=false
cleanup() {
  local code=$? pid svc
  trap '' INT TERM
  if [ -n "$MAIN_COMMAND_PID" ]; then JOB_SERVICE[$MAIN_COMMAND_PID]=preparation; fi
  # Kill only sessions created by this run, never the caller's process group.
  if [ "${#JOB_SERVICE[@]}" -gt 0 ]; then terminate_deploy_sessions "${!JOB_SERVICE[@]}"; fi
  for svc in "${!MIGRATION_STOPPED[@]}"; do rollback_migration "$svc" || true; done
  if $DEPLOY_STARTED_AGENT; then ssh-agent -k >/dev/null 2>&1 || true; fi
  if [ -n "$LOG_DIR" ]; then
    printf '\nLogs: %s\n' "$LOG_DIR"
    if $DRY_RUN; then info 'Dry run finished; persistent deployment state was not changed.'; fi
  fi
  if ! $DRY_RUN && ! $INTERRUPTED && command -v powershell.exe >/dev/null 2>&1; then
    local sound='C:\Windows\Media\tada.wav'
    [ "$code" -eq 0 ] || sound='C:\Windows\Media\chord.wav'
    powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '$sound').PlaySync()" >/dev/null 2>&1 || true
  fi
  return "$code"
}
trap cleanup EXIT
trap 'INTERRUPTED=true; exit 130' INT
trap 'INTERRUPTED=true; exit 143' TERM
if $DRY_RUN; then
  LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/deploy-kit-dry-run.XXXXXX")
else
  mkdir -p "${SCRIPT_DIR}/.deploy-logs"
  LOG_DIR=$(mktemp -d "${SCRIPT_DIR}/.deploy-logs/$(date +%Y%m%d-%H%M%S).XXXXXX")
fi
mkdir -p "$LOG_DIR/inputs" "$LOG_DIR/verified"
export DEPLOY_LOG_DIR="$LOG_DIR"
info "Deployment logs: $LOG_DIR"
$DRY_RUN && info 'DRY RUN — validation only; hooks, pulls, builds, and remote actions are skipped'
$SKIP_TESTS && warn 'Tests are explicitly disabled for this run'

# Keep main-process network work interruptible too (not just service workers).
run_foreground() {
  local budget="$1" code=0; shift
  setsid timeout --kill-after=5 "$budget" "$@" &
  MAIN_COMMAND_PID=$!
  wait "$MAIN_COMMAND_PID" || code=$?
  MAIN_COMMAND_PID=''
  return "$code"
}

# Pull before planning. A failure is fatal; comparing SHAs cannot classify a
# failed network operation as a successful update. Reparse after registry and
# package updates, since both can change the selected graph.
# Collect completions directly; status files are diagnostics, never a wait API.
wait_owned_job() {
  local known
  COLLECTED_PID='' COLLECTED_CODE=0
  for known in "${!JOB_SERVICE[@]}"; do
    if ! kill -0 "$known" 2>/dev/null; then
      wait "$known" || COLLECTED_CODE=$?
      COLLECTED_PID="$known"; return 0
    fi
  done
  wait -n -p COLLECTED_PID "${!JOB_SERVICE[@]}" || COLLECTED_CODE=$?
  [ -n "${COLLECTED_PID:-}" ] || die 'Could not collect an active deployment worker'
}
declare -A PULLED=() PULL_BEFORE=()
ANY_LIB_CHANGED=false
export ANY_LIB_CHANGED
finish_pull() {
  local id pid after
  wait_owned_job
  pid="$COLLECTED_PID"; id="${JOB_SERVICE[$pid]}"
  if [ "$COLLECTED_CODE" -ne 0 ]; then
    terminate_deploy_sessions "$pid"
    unset 'JOB_SERVICE[$pid]' 'JOB_PHASE[$pid]'
    cat "$LOG_DIR/$id.pull.log"; die "Pull failed: $id"
  fi
  unset 'JOB_SERVICE[$pid]' 'JOB_PHASE[$pid]'
  after=$(git -C "$ROOT_DIR/$id" rev-parse HEAD)
  PULLED[$id]=1
  if [[ "$id" == *-library ]] && [ "${PULL_BEFORE[$id]}" != "$after" ]; then ANY_LIB_CHANGED=true; fi
}
pull_repos() {
  local id pid
  for id in "$@"; do
    [ "${PULLED[$id]:-0}" = 0 ] || continue
    [ -d "$ROOT_DIR/$id" ] || die "Missing repository: $id"
    while [ "${#JOB_SERVICE[@]}" -ge "$MAX_CONCURRENT_SSH" ]; do finish_pull; done
    PULL_BEFORE[$id]=$(git -C "$ROOT_DIR/$id" rev-parse HEAD)
    step "Pulling $id"
    setsid timeout --kill-after=5 "$BUILD_PHASE_TIMEOUT" git -C "$ROOT_DIR/$id" pull --ff-only \
      > "$LOG_DIR/$id.pull.log" 2>&1 &
    pid=$!; JOB_SERVICE[$pid]="$id"; JOB_PHASE[$pid]=pull
  done
  while [ "${#JOB_SERVICE[@]}" -gt 0 ]; do finish_pull; done
}
if ! $DRY_RUN && ! $SKIP_PULL; then
  # Read the registry's newest roster before pulling selected applications.
  if [ -n "${SVC_DEPLOY_TARGET[vault-service]:-}" ]; then pull_repos vault-service; load_projects; select_services; fi
  selected_repos=()
  for svc in "${ALL_SERVICES[@]}"; do should_deploy "$svc" && selected_repos+=("$svc"); done
  pull_repos "${selected_repos[@]}"
  load_projects; select_services
fi
if ! $DRY_RUN && ! $SKIP_DEPS && ! $SKIP_PULL; then
  declare -A required_libs=()
  # A pulled library can introduce another dependency. Refresh the graph until
  # every library needed by the final plan has been synchronized.
  while :; do
    required_libs=(); next_libs=()
    for svc in "${ALL_SERVICES[@]}"; do
      if ! should_deploy "$svc" && ! { $CHANGED_ONLY && [ "$svc" = vault-service ]; }; then continue; fi
      for lib in ${SVC_LIB_DEPS[$svc]:-}; do required_libs[$lib]=1; done
    done
    for lib in "${LIBRARY_IDS[@]}"; do
      if [ "${required_libs[$lib]:-0}" = 1 ] && [ "${PULLED[$lib]:-0}" = 0 ]; then next_libs+=("$lib"); fi
    done
    [ "${#next_libs[@]}" -gt 0 ] || break
    pull_repos "${next_libs[@]}"
    load_projects; select_services
  done
fi
for svc in "${ALL_SERVICES[@]}"; do
  SVC_COLORS[$svc]=$(svc_color "$svc")
  SVC_SHARED[$svc]=0
  if grep -qE 'source .*deploy-kit/lib.sh' "${ROOT_DIR}/${svc}/deploy.sh" 2>/dev/null; then SVC_SHARED[$svc]=1; fi
  if should_deploy "$svc"; then
    [ -f "${ROOT_DIR}/${svc}/deploy.sh" ] || die "Missing deploy.sh for $svc"
  fi
done
snapshot_one() {
  node "$STATE_HELPER" snapshot --root "$ROOT_DIR" --kit "$SCRIPT_DIR" --config "$DEPLOY_CONFIG_DIR" \
    --projects "$PROJECTS_JSON" --service "$1" --libs "${SVC_LIB_DEPS[$1]:-}" --output "$2"
}
# These pairs include transitive libraries, and are shared with impact analysis.
pairs=''
for svc in "${ALL_SERVICES[@]}"; do
  if should_deploy "$svc" || [ "$svc" = vault-service ]; then
    libs="${SVC_LIB_DEPS[$svc]:-}"
    pairs+="${svc}:${libs// /,};"
  fi
done
node "$STATE_HELPER" snapshot --root "$ROOT_DIR" --kit "$SCRIPT_DIR" --config "$DEPLOY_CONFIG_DIR" \
  --projects "$PROJECTS_JSON" --pairs "$pairs" --out "$LOG_DIR/inputs"
if $CHANGED_ONLY && ! $BUILD_ONLY && [ -n "${SVC_DEPLOY_TARGET[vault-service]:-}" ]; then
  vault_target="${SVC_DEPLOY_TARGET[vault-service]}"
  if ! node "$STATE_HELPER" registry-matches --current "$LOG_DIR/inputs/vault-service.json" \
    --previous "$DEPLOY_STATE_ROOT/deployed/$vault_target/vault-service.json"; then
    [[ ",$SKIP_LIST," != *,vault-service,* ]] || die 'Registry changes require vault-service; remove --skip=vault-service.'
    SVC_SELECTED[vault-service]=1
    [ -f "${ROOT_DIR}/vault-service/deploy.sh" ] || die 'Registry changes require vault-service/deploy.sh'
    info 'Registry has not been deployed to this target — including vault-service before dependents'
  fi
fi
if $CHANGED_ONLY && ! $SKIP_DEPS && ! $NO_IMPACT; then
  if impact=$(node "${SCRIPT_DIR}/scripts/lib-impact.js" --root "$ROOT_DIR" --state "$DEPLOY_STATE_DIR" \
    --projects "$PROJECTS_JSON" --pairs "$pairs" 2>"$LOG_DIR/impact.log"); then
    eval "$impact"
  else
    warn 'Impact analysis failed; using conservative dependency comparison'
  fi
fi
state_file() { printf '%s/%s/%s/%s.json' "$DEPLOY_STATE_ROOT" "$1" "${SVC_DEPLOY_TARGET[$2]}" "$2"; }
set_status() { PHASE_STATUS[$1.$2]="$3"; printf '%s\n' "$3" > "$LOG_DIR/$1.$2.status"; }
changed_count=0 unrecorded_count=0
changed_verb=Deploying; $BUILD_ONLY && changed_verb=Building
for svc in "${ALL_SERVICES[@]}"; do
  SVC_CHANGED[$svc]=0; NEEDS_BUILD[$svc]=1
  if ! should_deploy "$svc"; then
    set_status "$svc" build SKIP; set_status "$svc" transfer SKIP; set_status "$svc" deploy SKIP; continue
  fi
  impact_verdict=''
  $IMPACT_SCRIPT_OK && impact_verdict="${IMPACT_VERDICT[$svc]:-}"
  if $CHANGED_ONLY; then
    # The helper says WHY a service is going out. "no deployment record" is the
    # one that matters: it means nothing has been recorded for this target yet
    # (only a healthy rollout writes the record), not that anything changed.
    if reason=$(node "$STATE_HELPER" matches --current "$LOG_DIR/inputs/$svc.json" \
      --previous "$(state_file "$STATE_MODE" "$svc")" --impact "$impact_verdict" --ignore-libraries "$SKIP_DEPS"); then
      # A build marker cannot make a deleted/replaced local image reusable.
      if ! $BUILD_ONLY && [ ! -f "$(state_file pending "$svc")" ]; then
        info "Skipping $svc (matches successful deployment)"
        set_status "$svc" build SKIP; set_status "$svc" transfer SKIP; set_status "$svc" deploy SKIP; continue
      fi
      reason=''; $BUILD_ONLY || reason='an earlier rollout did not finish'
    fi
    [ -z "$reason" ] || info "$changed_verb $svc — $reason"
    [[ "$reason" != 'no deployment record'* ]] || unrecorded_count=$((unrecorded_count + 1))
  fi
  SVC_CHANGED[$svc]=1; changed_count=$((changed_count + 1))
  if ! $NO_CACHE && [ "${SVC_SHARED[$svc]}" = 1 ] && node "$STATE_HELPER" matches >/dev/null \
    --current "$LOG_DIR/inputs/$svc.json" --previous "$(state_file built "$svc")" --impact "$impact_verdict" --ignore-libraries "$SKIP_DEPS"; then
    saved_image=$(node "$STATE_HELPER" image --input "$(state_file built "$svc")" --allow-untested "$SKIP_TESTS")
    current_image=$(timeout --kill-after=5 "$REMOTE_TIMEOUT" docker image inspect --format '{{.Id}}' "${svc}:latest" 2>/dev/null || true)
    if [ -n "$saved_image" ] && [ "$saved_image" = "$current_image" ]; then
      NEEDS_BUILD[$svc]=0; set_status "$svc" build OK
      info "Reusing verified local image for $svc"
    fi
  fi
done
if [ "$unrecorded_count" -gt 0 ]; then
  info "$unrecorded_count of $changed_count selected services have no deployment record under $DEPLOY_STATE_ROOT/$STATE_MODE — each goes out once to write one; only a healthy rollout records state, so an aborted run leaves them unrecorded"
  legacy_markers=("$DEPLOY_STATE_ROOT"/*.sha); [ -e "${legacy_markers[0]}" ] || legacy_markers=()
  [ "${#legacy_markers[@]}" -eq 0 ] || info "${#legacy_markers[@]} legacy .sha marker files in $DEPLOY_STATE_ROOT are not consulted (they were written before deployment completed) and are removed as services record state"
fi

# Remote commands are bounded and quoted once at the SSH boundary.
device_docker() {
  local device="$1"; shift
  if [ "${DEVICE_METHOD[$device]:-ssh}" = docker-api ]; then
    timeout --kill-after=5 "$REMOTE_TIMEOUT" docker -H "${DEVICE_DOCKER_API[$device]}" "$@"
  else
    local command
    printf -v command '%q ' sudo "${DEVICE_DOCKER_BIN[$device]:-/usr/local/bin/docker}" "$@"
    timeout --kill-after=5 "$REMOTE_TIMEOUT" ssh -o ConnectTimeout=8 -o BatchMode=yes \
      "${DEVICE_SSH_ALIAS[$device]:-nas}" "$command"
  fi
}
if ! $DRY_RUN && [ "$changed_count" -gt 0 ]; then
  start_deploy_agent
  declare -A foreign_arches=() selected_targets=()
  host_arch=$(uname -m)
  case "$host_arch" in x86_64) host_arch=amd64 ;; aarch64) host_arch=arm64 ;; esac
  for svc in "${ALL_SERVICES[@]}"; do
    [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
    target="${SVC_DEPLOY_TARGET[$svc]}"; selected_targets[$target]=1
    arch="${DEVICE_ARCH[$target]:-}"
    if [ "${NEEDS_BUILD[$svc]}" = 1 ] && [ "${SVC_SHARED[$svc]}" = 1 ] && [ -n "$arch" ] && [ "$arch" != "$host_arch" ]; then foreign_arches[$arch]=1; fi
  done
  for arch in "${!foreign_arches[@]}"; do
    case "$arch" in arm64) handler=qemu-aarch64 ;; amd64) handler=qemu-x86_64 ;; *) handler="qemu-$arch" ;; esac
    if [ ! -f "/proc/sys/fs/binfmt_misc/$handler" ]; then
      run_foreground "$BUILD_PHASE_TIMEOUT" docker run --privileged --rm tonistiigi/binfmt --install "$arch" || die "Cannot install emulator for $arch"
      [ -f "/proc/sys/fs/binfmt_misc/$handler" ] || die "Emulator unavailable: $handler"
    fi
  done
  if ! $BUILD_ONLY; then
    for target in "${!selected_targets[@]}"; do
      device_docker "$target" network prune -f > "$LOG_DIR/$target.network-prune.log" 2>&1 || warn "Network cleanup failed for $target; see logs"
    done
  fi
fi

export DEPLOY_ORCHESTRATED=true
launch_phase() {
  local svc="$1" phase="$2" target="${SVC_DEPLOY_TARGET[$1]}" budget
  local flags=()
  case "$phase" in
    build) flags+=(--build-only); budget="$BUILD_PHASE_TIMEOUT"
      # Legacy scripts may pull images remotely in their build phase. Validate
      # them here and execute their complete pipeline only in the deploy tier.
      [ "${SVC_SHARED[$svc]}" = 1 ] || flags+=(--dry-run) ;;
    transfer) flags+=(--transfer-only); budget="$TRANSFER_PHASE_TIMEOUT" ;;
    restart) flags+=(--restart-only); budget="$RESTART_PHASE_TIMEOUT" ;;
    deploy) budget="$BUILD_PHASE_TIMEOUT" ;;
  esac
  $DRY_RUN && flags+=(--dry-run)
  $NO_CACHE && flags+=(--no-cache)
  $SKIP_TESTS && flags+=(--skip-tests)
  # Shared wrappers already had their Git repositories pulled by this run.
  if $SKIP_PULL || [ "${SVC_SHARED[$svc]}" = 1 ]; then flags+=(--skip-pull); fi
  if [ "$phase" != build ] && ! $DRY_RUN; then
    snapshot_one "$svc" "$LOG_DIR/verified/$svc.json" || return 1
    drift=$(node "$STATE_HELPER" matches --current "$LOG_DIR/verified/$svc.json" --previous "$LOG_DIR/inputs/$svc.json") || {
      warn "$svc changed after build/planning ($drift); refusing to deploy mixed inputs"; return 1;
    }
    # Keep the last healthy receipt for rollback, but force a retry until every
    # mutating phase and health check has completed, even if source is reverted.
    node "$STATE_HELPER" record --input "$LOG_DIR/inputs/$svc.json" --output "$(state_file pending "$svc")" || return 1
  fi
  local previous_image
  previous_image=$(node "$STATE_HELPER" image --input "$(state_file deployed "$svc")")
  info "Starting $phase for $svc"
  DEPLOY_TARGET="$target" DEPLOY_METHOD="${DEVICE_METHOD[$target]:-ssh}" \
  DEPLOY_HOSTNAME="${DEVICE_HOSTNAME[$target]:-}" DEPLOY_ARCH="${DEVICE_ARCH[$target]:-}" \
  DEPLOY_SSH_HOST="${DEVICE_SSH_ALIAS[$target]:-nas}" DEPLOY_DOCKER_BIN="${DEVICE_DOCKER_BIN[$target]:-/usr/local/bin/docker}" \
  DEPLOY_DOCKER_API="${DEVICE_DOCKER_API[$target]:-}" DEPLOY_COMPOSE_ROOT="${DEVICE_COMPOSE_ROOT[$target]:-/volume1/docker}" \
  DEPLOY_SMB_ROOT="${DEVICE_SMB_ROOT[$target]:-/mnt/k}" DEPLOY_SERVICE_ID="$svc" \
  DEPLOY_SERVICE_COLOR="${SVC_COLORS[$svc]}" DEPLOY_COLOR_RESET="$RESET" \
  DEPLOY_PHASE_LOG="$LOG_DIR/$svc.$phase.log" DEPLOY_DOCKER_LOG="$LOG_DIR/$svc.docker.log" \
  DEPLOY_PREVIOUS_IMAGE="$previous_image" \
  DEPLOY_BUILD_SNAPSHOT="$LOG_DIR/inputs/$svc.json" DEPLOY_LIBRARY_IDS="${SVC_LIB_DEPS[$svc]:-}" \
  DEPLOY_STATE_HELPER="$STATE_HELPER" \
    setsid timeout --kill-after=5 "$budget" bash "$SCRIPT_DIR/scripts/run-service.sh" \
      "$SCRIPT_DIR" "$ROOT_DIR/$svc/deploy.sh" "${flags[@]}" &
  local pid=$!
  JOB_SERVICE[$pid]="$svc"; JOB_PHASE[$pid]="$phase"
  set_status "$svc" "$phase" RUNNING
}
finish_job() {
  local pid="$1" code="$2" svc="${JOB_SERVICE[$1]}" phase="${JOB_PHASE[$1]}" image
  # timeout/worker death may leave descendants. Reap the whole owned session.
  if [ "$code" -ne 0 ]; then terminate_deploy_sessions "$pid"; fi
  unset 'JOB_SERVICE[$pid]' 'JOB_PHASE[$pid]'
  if [ "$code" -eq 0 ] && [ "$phase" = build ] && ! $DRY_RUN && [ "${SVC_SHARED[$svc]}" = 1 ]; then
    if ! snapshot_one "$svc" "$LOG_DIR/verified/$svc.json" || ! drift=$(node "$STATE_HELPER" matches \
      --current "$LOG_DIR/verified/$svc.json" --previous "$LOG_DIR/inputs/$svc.json"); then
      warn "$svc inputs changed during its build (${drift:-snapshot failed}); image will not be reused"; code=1
    else
      image=$(timeout --kill-after=5 "$REMOTE_TIMEOUT" docker image inspect --format '{{.Id}}' "${svc}:latest" 2>/dev/null || true)
      if [ -z "$image" ]; then code=1; warn "$svc produced no local image"
      elif ! node "$STATE_HELPER" record --input "$LOG_DIR/inputs/$svc.json" --image "$image" --output "$(state_file built "$svc")" --unknown-libraries "$SKIP_DEPS" --tests-skipped "$SKIP_TESTS"; then code=1; fi
    fi
  fi
  if [ "$code" -eq 0 ]; then set_status "$svc" "$phase" OK; ok "$svc $phase complete"
  else set_status "$svc" "$phase" FAIL; fail "$svc $phase failed (exit $code) — $LOG_DIR/$svc.$phase.log"; fi
  if [ "$phase" = build ] && [ "$code" -ne 0 ]; then set_status "$svc" transfer FAIL; set_status "$svc" deploy FAIL; fi
  if [ "$phase" = transfer ] && [ "$code" -ne 0 ]; then set_status "$svc" deploy FAIL; fi
}
wait_job() {
  wait_owned_job
  finish_job "$COLLECTED_PID" "$COLLECTED_CODE"
}
pump_preparation() {
  local builds=0 transfers=0 pid svc
  if $NO_PARALLEL && [ "${#JOB_SERVICE[@]}" -gt 0 ]; then return 0; fi
  for pid in "${!JOB_PHASE[@]}"; do
    case "${JOB_PHASE[$pid]}" in build) builds=$((builds + 1)) ;; *) transfers=$((transfers + 1)) ;; esac
  done
  for svc in "${ALL_SERVICES[@]}"; do
    [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
    if [ -z "${PHASE_STATUS[$svc.build]:-}" ] && [ "$builds" -lt "$MAX_CONCURRENT_BUILDS" ]; then
      launch_phase "$svc" build; builds=$((builds + 1))
      $NO_PARALLEL && return 0
    fi
    if ! $BUILD_ONLY && [ "${PHASE_STATUS[$svc.build]:-}" = OK ] && [ -z "${PHASE_STATUS[$svc.transfer]:-}" ]; then
      if [ "${SVC_SHARED[$svc]}" = 0 ]; then set_status "$svc" transfer OK
      elif [ "$transfers" -lt "$MAX_CONCURRENT_SSH" ]; then
        if launch_phase "$svc" transfer; then transfers=$((transfers + 1)); if $NO_PARALLEL; then return 0; fi; else set_status "$svc" transfer FAIL; set_status "$svc" deploy FAIL; fi
      fi
    fi
  done
}
tier_prepared() {
  local svc phase=transfer
  $BUILD_ONLY && phase=build
  for svc in "$@"; do
    [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
    case "${PHASE_STATUS[$svc.$phase]:-}" in OK|FAIL) ;; *) return 1 ;; esac
  done
  return 0
}
wait_prepared() {
  while :; do
    # Sequential mode must finish this tier before starting a later build.
    if $NO_PARALLEL && tier_prepared "$@"; then return 0; fi
    pump_preparation
    tier_prepared "$@" && return 0
    [ "${#JOB_SERVICE[@]}" -gt 0 ] || die 'Preparation has no active workers but incomplete services'
    wait_job
  done
}

discover_migrations() {
  local device svc target names
  for device in "${DOCKER_DEVICES[@]}"; do
    if names=$(device_docker "$device" ps -a --format '{{.Names}}' 2>"$LOG_DIR/$device.containers.log"); then
      DEVICE_REACHABLE[$device]=1; DEVICE_CONTAINERS[$device]="$names"
    else DEVICE_REACHABLE[$device]=0; warn "Cannot check existing containers on $device"; fi
  done
  for svc in "${ALL_SERVICES[@]}"; do
    [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
    target="${SVC_DEPLOY_TARGET[$svc]}"
    for device in "${DOCKER_DEVICES[@]}"; do
      [ "$device" != "$target" ] || continue
      if [ "${DEVICE_REACHABLE[$device]}" = 0 ]; then
        [ ! -f "$DEPLOY_STATE_ROOT/deployed/$device/$svc.json" ] || die "Cannot safely migrate $svc: previous target $device is unreachable"
        continue
      fi
      case $'\n'"${DEVICE_CONTAINERS[$device]}"$'\n' in
        *$'\n'"$svc"$'\n'*) MIGRATION_SOURCES[$svc]="${MIGRATION_SOURCES[$svc]:-} $device" ;;
      esac
    done
  done
}
stop_migration_sources() {
  local svc="$1" device
  for device in ${MIGRATION_SOURCES[$svc]:-}; do
    # Preserve the old container (including its image/config) for rollback.
    MIGRATION_STOPPED[$svc]="${MIGRATION_STOPPED[$svc]:-} $device"
    device_docker "$device" stop "$svc" >>"$LOG_DIR/$svc.migration.log" 2>&1 || return 1
  done
}
rollback_migration() {
  local svc="$1" target="${SVC_DEPLOY_TARGET[$1]}" device names
  [ -n "${MIGRATION_STOPPED[$svc]:-}" ] || return 0
  warn "Restoring $svc on its previous target"
  # Avoid duplicate workers if the new target cannot be reached/stopped.
  if ! names=$(device_docker "$target" ps -a --filter "name=^/${svc}$" --format '{{.Names}}'); then
    warn "Cannot confirm $svc stopped on $target; previous containers retained for recovery"; return 1
  fi
  if [ -n "$names" ]; then device_docker "$target" stop "$svc" || return 1; fi
  for device in ${MIGRATION_STOPPED[$svc]}; do device_docker "$device" start "$svc" || return 1; done
  unset 'MIGRATION_STOPPED[$svc]'
}
wait_tier_healthy() {
  local tier="$1"; shift
  local svc deadline=$((SECONDS + HEALTH_GATE_TIMEOUT)) code check_dir pid remaining
  local pids=()
  local -A pending=()
  for svc in "$@"; do
    if [ "${PHASE_STATUS[$svc.deploy]:-}" = OK ] && [ -n "${SVC_HEALTH_URL[$svc]:-}" ]; then pending[$svc]=1; fi
    # An unchanged foundation still has to be available for new dependents.
    if [ "$tier" = 0 ] && [ "${SVC_CHANGED[$svc]}" = 0 ] && [ -n "${SVC_HEALTH_URL[$svc]:-}" ]; then pending[$svc]=1; fi
  done
  while [ "${#pending[@]}" -gt 0 ] && [ "$SECONDS" -lt "$deadline" ]; do
    check_dir=$(mktemp -d "$LOG_DIR/.health.XXXXXX"); pids=()
    remaining=$((deadline - SECONDS)); [ "$remaining" -le 3 ] || remaining=3
    for svc in "${!pending[@]}"; do
      (
        code=$(curl -sS --max-time "$remaining" -o /dev/null -w '%{http_code}' "${SVC_HEALTH_URL[$svc]}" 2>/dev/null) || exit 1
        [[ "$code" == 2[0-9][0-9] ]] && : > "$check_dir/$svc"
      ) & pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    for svc in "${!pending[@]}"; do
      if [ -f "$check_dir/$svc" ]; then set_status "$svc" health OK; ok "$svc healthy"; unset 'pending[$svc]'; fi
    done
    rm -rf "$check_dir"
    if [ "${#pending[@]}" -gt 0 ] && [ "$SECONDS" -lt "$deadline" ]; then
      remaining=$((deadline - SECONDS)); [ "$remaining" -le "$HEALTH_GATE_INTERVAL" ] || remaining="$HEALTH_GATE_INTERVAL"
      sleep "$remaining"
    fi
  done
  for svc in "${!pending[@]}"; do set_status "$svc" health UNHEALTHY; fail "$svc did not become healthy"; done
  [ "${#pending[@]}" -eq 0 ]
}
finalize_service() {
  local svc="$1" device input
  [ "${PHASE_STATUS[$svc.deploy]:-}" = OK ] || { rollback_migration "$svc"; return 1; }
  if [ "${PHASE_STATUS[$svc.health]:-}" = UNHEALTHY ]; then rollback_migration "$svc"; return 1; fi
  # At this point the replacement has passed its health check. Never start the
  # old copy again if later cleanup fails; leave it stopped for a retry.
  unset 'MIGRATION_STOPPED[$svc]'
  for device in ${MIGRATION_SOURCES[$svc]:-}; do
    if ! device_docker "$device" rm "$svc" >>"$LOG_DIR/$svc.migration.log" 2>&1; then
      set_status "$svc" deploy FAIL; warn "Could not clean up old $svc on $device"; return 1
    fi
    rm -f "$DEPLOY_STATE_ROOT/deployed/$device/$svc.json" "$DEPLOY_STATE_ROOT/pending/$device/$svc.json"
  done
  snapshot_one "$svc" "$LOG_DIR/verified/$svc.json" || { set_status "$svc" deploy FAIL; return 1; }
  drift=$(node "$STATE_HELPER" matches --current "$LOG_DIR/verified/$svc.json" --previous "$LOG_DIR/inputs/$svc.json") || {
    set_status "$svc" deploy FAIL; warn "$svc inputs changed during deployment ($drift); state was not advanced"; return 1;
  }
  input="$LOG_DIR/inputs/$svc.json"
  [ "${SVC_SHARED[$svc]}" = 0 ] || input="$(state_file built "$svc")"
  if ! node "$STATE_HELPER" record --input "$input" --output "$(state_file deployed "$svc")" --unknown-libraries "$SKIP_DEPS"; then
    set_status "$svc" deploy FAIL; return 1
  fi
  # The record supersedes the pre-2026-09-10 markers, which were written before
  # a deployment completed and are never consulted; retire them with it.
  rm -f "$(state_file pending "$svc")" "$DEPLOY_STATE_ROOT/$svc.sha" "$DEPLOY_STATE_ROOT/$svc.deps.sha"
}

aborted=false
if $BUILD_ONLY; then
  wait_prepared "${ALL_SERVICES[@]}"
else
  pump_preparation
  if ! $DRY_RUN && [ "$changed_count" -gt 0 ]; then discover_migrations; fi
  for ((tier=0; tier<=MAX_TIER; tier++)); do
    read -ra tier_svcs <<< "${TIER_SERVICES[$tier]:-}"
    [ "${#tier_svcs[@]}" -gt 0 ] || continue
    header "Tier $tier — prepare, restart, verify"
    wait_prepared "${tier_svcs[@]}"
    tier_failed=false
    for svc in "${tier_svcs[@]}"; do
      if [ "${SVC_CHANGED[$svc]}" = 1 ] && [ "${PHASE_STATUS[$svc.transfer]:-}" != OK ]; then tier_failed=true; fi
    done
    if [ "$tier" -eq 0 ] && $tier_failed; then aborted=true; fail 'Foundation preparation failed; dependent tiers will not restart'; break; fi
    # Bound restarts as well as transfers; unrelated preparations can finish
    # while these jobs run, and all exits are collected by the same parent.
    for svc in "${tier_svcs[@]}"; do
      [ "${SVC_CHANGED[$svc]}" = 1 ] && [ "${PHASE_STATUS[$svc.transfer]:-}" = OK ] || continue
      while :; do
        remote_jobs=0
        for pid in "${!JOB_PHASE[@]}"; do [ "${JOB_PHASE[$pid]}" = build ] || remote_jobs=$((remote_jobs + 1)); done
        [ "$remote_jobs" -lt "$MAX_CONCURRENT_SSH" ] && break
        wait_job
      done
      phase=restart; [ "${SVC_SHARED[$svc]}" = 1 ] || phase=deploy
      if ! $DRY_RUN && ! stop_migration_sources "$svc"; then
        set_status "$svc" deploy FAIL; rollback_migration "$svc" || true; tier_failed=true; continue
      fi
      if ! launch_phase "$svc" "$phase"; then set_status "$svc" deploy FAIL; tier_failed=true; fi
    done
    while :; do
      restarting=false
      for pid in "${!JOB_PHASE[@]}"; do case "${JOB_PHASE[$pid]}" in restart|deploy) restarting=true ;; esac; done
      $restarting || break
      wait_job
    done
    for svc in "${tier_svcs[@]}"; do
      [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
      if [ -n "${PHASE_STATUS[$svc.restart]:-}" ]; then set_status "$svc" deploy "${PHASE_STATUS[$svc.restart]:-}"; fi
      [ "${PHASE_STATUS[$svc.deploy]:-}" = OK ] || tier_failed=true
    done
    if ! $DRY_RUN && [ "$changed_count" -gt 0 ]; then
      wait_tier_healthy "$tier" "${tier_svcs[@]}" || tier_failed=true
      for svc in "${tier_svcs[@]}"; do
        [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
        finalize_service "$svc" || tier_failed=true
      done
    fi
    if $tier_failed; then aborted=true; fail "Tier $tier failed; subsequent tiers will not restart"; break; fi
  done
fi
# Finish or cancel all preparation workers before global cleanup. On an abort,
# EXIT cleanup terminates them; do not prune while they are still running.
if ! $aborted; then
  while [ "${#JOB_SERVICE[@]}" -gt 0 ]; do wait_job; done
fi
if ! $DRY_RUN && ! $aborted && [ "$changed_count" -gt 0 ]; then
  step 'Cleaning images once per host and retaining a bounded build cache'
  local_tags=()
  for svc in "${ALL_SERVICES[@]}"; do
    [ "${SVC_CHANGED[$svc]}" = 1 ] || continue
    while IFS= read -r tag; do
      case "$tag" in "$svc":latest|"$svc":previous|*:'<none>'|'') ;; *) local_tags+=("$tag") ;; esac
    done < <(docker images "$svc" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  done
  if [ "${#local_tags[@]}" -gt 0 ]; then docker rmi "${local_tags[@]}" > "$LOG_DIR/local-tags.log" 2>&1 || warn 'Some local tags could not be removed'; fi
  run_foreground "$REMOTE_TIMEOUT" docker image prune -f > "$LOG_DIR/local-prune.log" 2>&1 || warn 'Local image cleanup failed'
  cache_flags=(--keep-storage "$BUILD_CACHE_KEEP_STORAGE")
  [ -z "$BUILD_CACHE_MAX_AGE" ] || cache_flags+=(--filter "until=$BUILD_CACHE_MAX_AGE")
  run_foreground "$BUILD_PHASE_TIMEOUT" docker builder prune -f --all "${cache_flags[@]}" \
    > "$LOG_DIR/build-cache.log" 2>&1 || warn 'Build cache cleanup failed'
  if ! $BUILD_ONLY; then
    for target in "${!selected_targets[@]}"; do
      tags=()
      for svc in "${ALL_SERVICES[@]}"; do
        [ "${SVC_CHANGED[$svc]}" = 1 ] && [ "${SVC_DEPLOY_TARGET[$svc]}" = "$target" ] && [ "${PHASE_STATUS[$svc.deploy]:-}" = OK ] || continue
        while IFS= read -r tag; do
          case "$tag" in "$svc":latest|"$svc":previous|*:'<none>'|'') ;; *) tags+=("$tag") ;; esac
        done < <(device_docker "$target" images "$svc" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
      done
      if [ "${#tags[@]}" -gt 0 ]; then device_docker "$target" rmi "${tags[@]}" > "$LOG_DIR/$target.tags.log" 2>&1 || warn "Tag cleanup failed for $target"; fi
      device_docker "$target" image prune -f > "$LOG_DIR/$target.prune.log" 2>&1 || warn "Image cleanup failed for $target"
    done
  fi
fi
PASS=0 FAILED=0 SKIPPED=0 UNHEALTHY_COUNT=0
header 'Deploy All — Summary'
summary_phase=deploy; $BUILD_ONLY && summary_phase=build
for svc in "${ALL_SERVICES[@]}"; do
  result=${PHASE_STATUS[$svc.$summary_phase]:-}
  if [ "${PHASE_STATUS[$svc.health]:-}" = UNHEALTHY ]; then
    UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1)); warn "$svc unhealthy"
  elif [ "$result" = OK ]; then PASS=$((PASS + 1)); ok "$svc"
  elif [ "$result" = FAIL ] || { [ "${SVC_CHANGED[$svc]}" = 1 ] && [ "$result" != OK ]; }; then
    FAILED=$((FAILED + 1)); fail "$svc failed or blocked"
  else SKIPPED=$((SKIPPED + 1)); fi
done
# Edge changes are deployment actions, and only follow a successful rollout.
if ! $DRY_RUN && ! $BUILD_ONLY && ! $aborted && [ "$FAILED" -eq 0 ] && [ "$UNHEALTHY_COUNT" -eq 0 ] && [ "$changed_count" -gt 0 ]; then
  if ! run_foreground "$TRANSFER_PHASE_TIMEOUT" node "$SCRIPT_DIR/edge/reconcile-dns.js" --apply > "$LOG_DIR/edge-dns.log" 2>&1; then warn "Edge DNS reconciliation failed — $LOG_DIR/edge-dns.log"; fi
  if ! run_foreground "$TRANSFER_PHASE_TIMEOUT" bash "$SCRIPT_DIR/edge/sync-config.sh" > "$LOG_DIR/edge-sync.log" 2>&1; then warn "Edge config sync failed — $LOG_DIR/edge-sync.log"; fi
fi
printf '\n%d passed, %d unhealthy, %d failed, %d skipped (%ds)\n' "$PASS" "$UNHEALTHY_COUNT" "$FAILED" "$SKIPPED" "$((SECONDS - DEPLOY_START))"
if ! $DRY_RUN && $COMPACT_WSL && ! $aborted && [ "$FAILED" -eq 0 ] && [ "$UNHEALTHY_COUNT" -eq 0 ]; then
  bash "$SCRIPT_DIR/scripts/compact-wsl.sh"
fi
! $aborted && [ "$FAILED" -eq 0 ] && [ "$UNHEALTHY_COUNT" -eq 0 ]
