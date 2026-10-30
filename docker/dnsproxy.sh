#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
# shellcheck source=docker/lib.sh
source "$SCRIPT_DIR/lib.sh"

DNSPROXY_BIN="${DNSPROXY_BIN:-/usr/local/bin/dnsproxy}"
DNSPROXY_CONF="${DNSPROXY_CONF:-}"

if ! dnsproxy_enabled; then
    log "DNSPROXY_CONF is empty, dnsproxy is disabled"
    exit 0
fi

[ -x "$DNSPROXY_BIN" ] || die "dnsproxy not found: $DNSPROXY_BIN (rebuild the image)"

mkdir -p "$RUNTIME_DIR"

read -r -a dnsproxy_args <<< "${DNSPROXY_CONF//$'\n'/ }"
[ "${#dnsproxy_args[@]}" -gt 0 ] || die "DNSPROXY_CONF contains no command-line flags"

doh_hosts="$(dnsproxy_doh_hosts | paste -sd ' ' -)"
if [ -n "$doh_hosts" ]; then
    log "dnsproxy DoH host(s) for zapret hostlists: $doh_hosts"
fi

child=""
shutdown_requested=0

stop_child() {
    [ -n "$child" ] || return 0
    kill -0 "$child" 2>/dev/null || return 0
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
}

on_term() {
    shutdown_requested=1
    stop_child
}

trap on_term TERM INT
trap 'stop_child' EXIT

while [ "$shutdown_requested" -eq 0 ]; do
    log "Starting dnsproxy..."
    "$DNSPROXY_BIN" "${dnsproxy_args[@]}" &
    child=$!
    printf '%s\n' "$child" > "$RUNTIME_DIR/dnsproxy.pid"

    set +e
    wait "$child"
    rc=$?
    set -e

    child=""
    rm -f "$RUNTIME_DIR/dnsproxy.pid"

    [ "$shutdown_requested" -eq 1 ] && break

    log "dnsproxy exited with code $rc, restarting in 2 seconds..."
    sleep 2
done
