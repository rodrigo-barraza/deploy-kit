#!/bin/bash
# Shared process and workspace helpers. Safe to source before parsing flags.
deploy_paths() {
  local kit="$1" common
  DEPLOY_KIT_HOME="$kit"
  if common=$(git -C "$kit" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    [ "${common##*/}" != .git ] || DEPLOY_KIT_HOME="${common%/.git}"
  fi
  ROOT_DIR="${DEPLOY_ROOT_DIR:-$(dirname "$DEPLOY_KIT_HOME")}"
  ROOT_DIR=$(cd "$ROOT_DIR" && pwd)
  DEPLOY_CONFIG_DIR="${DEPLOY_CONFIG_DIR:-$DEPLOY_KIT_HOME}"
  DEPLOY_STATE_ROOT="${DEPLOY_STATE_ROOT:-${DEPLOY_KIT_HOME}/.deploy-state}"
  export DEPLOY_ROOT_DIR="$ROOT_DIR" DEPLOY_CONFIG_DIR DEPLOY_STATE_ROOT
}
positive_integer() {
  local value="$2" maximum="${3:-86400}"
  if [[ ! "$value" =~ ^[1-9][0-9]{0,5}$ ]] || (( value > maximum )); then
    printf 'ERROR: %s must be an integer from 1 to %s (got %s)\n' "$1" "$maximum" "$value" >&2
    return 1
  fi
}
acquire_deploy_lock() {
  local key lock_dir="${TMPDIR:-/tmp}"
  key=$(printf '%s' "$ROOT_DIR" | sha256sum)
  # One lock per workspace, including standalone scripts and linked worktrees.
  # Keep the inode: unlinking an active flock file would permit a second owner.
  exec 9>"${lock_dir}/deploy-kit-${UID}-${key%% *}.lock"
  flock -n 9 || { printf 'ERROR: Another deployment is running for %s\n' "$ROOT_DIR" >&2; return 1; }
}
start_deploy_agent() {
  local status=0
  ssh-add -l >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ] || [ -z "${SSH_AUTH_SOCK:-}" ]; then
    eval "$(ssh-agent -s)" >/dev/null
    DEPLOY_STARTED_AGENT=true
    export SSH_AUTH_SOCK SSH_AGENT_PID
  fi
  ssh-add -l >/dev/null 2>&1 || ssh-add </dev/null >/dev/null 2>&1 || true
}

# Give EXIT traps time to restore staged configuration before killing survivors.
# The direct PID signal also covers cancellation just before setsid takes effect.
terminate_deploy_sessions() {
  local pid attempt alive
  for pid in "$@"; do
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for attempt in {1..30}; do
    alive=false
    for pid in "$@"; do
      if kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then alive=true; fi
    done
    $alive || break
    sleep 0.1
  done
  for pid in "$@"; do
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
