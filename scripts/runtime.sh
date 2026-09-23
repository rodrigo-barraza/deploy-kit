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
# Every build and transfer needs the local daemon. Docker Desktop not running cost
# five whole runs on 2026-09-18/20: pulls, planning and a remote network prune,
# then every build dead in 0 s on a missing docker.sock. Check it before any of
# that; where Docker Desktop is installed (WSL), start it and wait for it.
ensure_docker() {
  local budget="${DOCKER_START_TIMEOUT:-120}" desktop cli deadline restarted=false
  positive_integer DOCKER_START_TIMEOUT "$budget" 3600 || return 1
  timeout --kill-after=5 15 docker info >/dev/null 2>&1 && return 0
  desktop="${DOCKER_DESKTOP_EXE:-/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe}"
  if [ ! -f "$desktop" ] || ! command -v powershell.exe >/dev/null 2>&1; then
    printf 'ERROR: the local Docker daemon is not answering (docker info failed); start Docker and re-run\n' >&2
    return 1
  fi
  deadline=$((SECONDS + budget))
  # Docker Desktop can be running with its WSL integration stopped: `wsl --shutdown`
  # under it leaves the engine up and no docker.sock in the distro (2026-09-22), and
  # starting an already running Desktop does nothing. Only a restart re-attaches it,
  # and a restart stops local containers, so it is skipped while any are running.
  cli="${DOCKER_DESKTOP_CLI:-$(dirname "$desktop")/resources/bin/docker.exe}"
  if [ -f "$cli" ] && timeout --kill-after=5 20 "$cli" desktop status 2>/dev/null | tr -d '\r' | grep -qE '^Status[[:space:]]+running[[:space:]]*$'; then
    if [ -n "$(timeout --kill-after=5 20 "$cli" --context desktop-linux ps -q 2>/dev/null | tr -d '\r')" ]; then
      printf 'ERROR: Docker Desktop is running but its WSL integration is stopped (no docker.sock in %s).\n' "${WSL_DISTRO_NAME:-this distro}" >&2
      printf '       Local containers are running, so it was not restarted: click "Restart the WSL integration" in Docker Desktop, or run docker.exe desktop restart\n' >&2
      return 1
    fi
    printf 'Docker Desktop is running but its WSL integration is stopped; restarting Docker Desktop (waiting up to %ss)\n' "$budget" >&2
    timeout --kill-after=5 "$budget" "$cli" desktop restart >/dev/null 2>&1 || true
    restarted=true
  else
    printf 'Docker is not running; starting Docker Desktop (waiting up to %ss)\n' "$budget" >&2
    # Start-Process detaches it, so it outlives this run and its cancellation.
    powershell.exe -NoProfile -Command "Start-Process -FilePath '$(wslpath -w "$desktop" 2>/dev/null || printf '%s' "$desktop")'" \
      >/dev/null 2>&1 || true
  fi
  until timeout --kill-after=5 15 docker info >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      if $restarted; then
        printf 'ERROR: Docker Desktop restarted but %s still has no docker.sock; check Settings > Resources > WSL integration\n' "${WSL_DISTRO_NAME:-this distro}" >&2
      else
        printf 'ERROR: Docker Desktop did not answer within %ss\n' "$budget" >&2
      fi
      return 1
    fi
    sleep 2
  done
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
