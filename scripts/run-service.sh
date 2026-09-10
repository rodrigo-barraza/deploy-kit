#!/bin/bash
# Runs inside its own session under timeout. The parent owns status files and
# collects the exit code even if this process is killed before it can report.
set -euo pipefail
kit="$1"; service_script="$2"; shift 2
export DEPLOY_KIT_DIR="$kit"
# Existing wrappers source ../deploy-kit/lib.sh. Resolve that source to the
# selected kit checkout so a linked worktree also runs its own shared library.
bash -euo pipefail -c '
  _DEPLOY_WRAPPER_ARGS=("$@")
  source() {
    case "$1" in
      */deploy-kit/lib.sh) shift; builtin source "$DEPLOY_KIT_DIR/lib.sh" "${_DEPLOY_WRAPPER_ARGS[@]}" ;;
      *) builtin source "$@" ;;
    esac
  }
  builtin source "$0" "$@"
' "$service_script" "$@" 2>&1 | tee "$DEPLOY_PHASE_LOG" | while IFS= read -r line || [ -n "$line" ]; do
  printf '%s[%s]%s %s\n' "${DEPLOY_SERVICE_COLOR:-}" "$DEPLOY_SERVICE_ID" "${DEPLOY_COLOR_RESET:-}" "$line"
done
