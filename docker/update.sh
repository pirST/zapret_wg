#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
# shellcheck source=docker/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<'EOF'
Usage: zapret-wg-update [--latest] [download-deps options]

  (no options)   Update adapter, then install recommended nfqws/strategies.
  --latest       Update adapter, then install latest nfqws and latest strategies.
  -z VER         Pass a zapret version to the adapter's download-deps.
  -s VER         Pass a strategies version to the adapter's download-deps.

The running zapret is paused, updated and restarted automatically.
EOF
}

LATEST=0
PASSTHROUGH=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --latest)
            LATEST=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

[ -d "$ADAPTER_DIR/.git" ] || die "Adapter git repository not found: $ADAPTER_DIR"
command -v git >/dev/null 2>&1 || die "git is not installed"

mkdir -p "$RUNTIME_DIR"
touch "$MAINTENANCE_FILE"

cleanup() {
    rm -f "$MAINTENANCE_FILE"
}
trap cleanup EXIT

# Give a runner that is starting right now a chance to publish its PID, so it
# can be stopped instead of racing with the dependency download.
for _ in $(seq 1 10); do
    [ -s "$RUNTIME_DIR/runner.pid" ] && break
    sleep 0.1
done

log "Pausing zapret for the update..."
if [ -s "$RUNTIME_DIR/runner.pid" ]; then
    runner_pid=$(cat "$RUNTIME_DIR/runner.pid")
    if kill -0 "$runner_pid" 2>/dev/null; then
        kill -TERM "$runner_pid" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$runner_pid" 2>/dev/null || break
            sleep 0.2
        done
    fi
fi
pkill -x nfqws 2>/dev/null || true
rm -f "$RUNTIME_DIR/runner.pid" "$RUNTIME_DIR/nfqws.pid"

log "Updating adapter scripts (git pull)..."
GIT_TERMINAL_PROMPT=0 git -C "$ADAPTER_DIR" pull --ff-only \
    || die "Failed to update the adapter from git"

if [ "${#PASSTHROUGH[@]}" -gt 0 ]; then
    log "Downloading dependencies with custom arguments: ${PASSTHROUGH[*]}"
    (cd "$ADAPTER_DIR" && ./service.sh download-deps "${PASSTHROUGH[@]}")
elif [ "$LATEST" -eq 1 ]; then
    log "Downloading latest nfqws and strategies..."
    (cd "$ADAPTER_DIR" && ./service.sh download-deps -z latest -s main)
else
    log "Downloading recommended nfqws and strategy versions..."
    (cd "$ADAPTER_DIR" && ./service.sh download-deps --default)
fi

[ -x "$NFQWS_PATH" ] || die "Update failed: $NFQWS_PATH is missing"
[ -d "$REPO_DIR" ] || die "Update failed: $REPO_DIR is missing"

rm -f "$MAINTENANCE_FILE"
trap - EXIT

log "Components updated."

pid1_cmd="$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null || true)"
if [[ "$pid1_cmd" == *entrypoint.sh* ]]; then
    log "Restarting zapret..."
    kill -USR1 1 2>/dev/null || warn "Could not signal PID 1; restart the container to apply updates"
else
    log "Entrypoint not detected; restart the container to apply updates."
fi
