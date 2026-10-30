#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
# shellcheck source=docker/lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=docker/wireguard.sh
source "$SCRIPT_DIR/wireguard.sh"

# Allow "docker run ... image bash" to open a shell without starting the service.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

export WG_CONFIG="${WG_CONFIG:-/opt/config/wg0.conf}"
export WG_INTERFACE="${WG_INTERFACE:-wg0}"
export WG_AUTOGEN="${WG_AUTOGEN:-1}"
export ZAPRET_STRATEGY="${ZAPRET_STRATEGY:-general_alt9.bat}"
export ZAPRET_EXTRA_HOSTS="${ZAPRET_EXTRA_HOSTS:-}"

mkdir -p "$RUNTIME_DIR" "$(dirname "$WG_CONFIG")"
rm -f "$MAINTENANCE_FILE" "$RUNTIME_DIR/runner.pid" "$RUNTIME_DIR/nfqws.pid"

if [ ! -s "$WG_CONFIG" ]; then
    if [ "$WG_AUTOGEN" = "1" ]; then
        log "WireGuard config not found, generating a new one: $WG_CONFIG"
        "$SCRIPT_DIR/genconfig.sh" "$WG_CONFIG"
    else
        die "WireGuard config not found: $WG_CONFIG (set WG_AUTOGEN=1 to generate one)"
    fi
fi

WAN_IFACE="$(detect_wan_iface)"
export WAN_IFACE
log "WAN interface: $WAN_IFACE"

setup_forwarding
setup_wireguard "$WG_CONFIG" "$WG_INTERFACE"

WG_LISTEN_PORT="$(wg show "$WG_INTERFACE" listen-port 2>/dev/null || true)"
export WG_LISTEN_PORT
[ -n "$WG_LISTEN_PORT" ] || warn "Could not determine the WireGuard listen port"

setup_nat "$WAN_IFACE"
setup_mss_clamp

zapret_pid=""
restart_requested=0
shutdown_requested=0

on_term() {
    shutdown_requested=1
    if [ -n "$zapret_pid" ] && kill -0 "$zapret_pid" 2>/dev/null; then
        kill -TERM "$zapret_pid" 2>/dev/null || true
    fi
}

on_usr1() {
    restart_requested=1
    if [ -n "$zapret_pid" ] && kill -0 "$zapret_pid" 2>/dev/null; then
        log "Restart requested"
        kill -TERM "$zapret_pid" 2>/dev/null || true
    fi
}

# wait() returns immediately when a trapped signal interrupts it, even though
# the runner may still be removing nftables rules. Keep waiting until the
# runner process is really gone and reaped.
wait_for_runner() {
    local pid="$1" wrc

    while :; do
        set +e
        wait "$pid" 2>/dev/null
        wrc=$?
        set -e

        # 127 means "not a child any more" (already reaped).
        [ "$wrc" -eq 127 ] && return 0
        kill -0 "$pid" 2>/dev/null || return 0
    done
}

trap on_term TERM INT
trap on_usr1 USR1

while :; do
    while [ -e "$MAINTENANCE_FILE" ] && [ "$shutdown_requested" -eq 0 ]; do
        sleep 1
    done

    [ "$shutdown_requested" -eq 1 ] && break

    # A start satisfies any restart request received during maintenance.
    restart_requested=0

    log "Starting zapret (strategy: $ZAPRET_STRATEGY)"
    "$SCRIPT_DIR/zapret.sh" &
    zapret_pid=$!
    printf '%s\n' "$zapret_pid" > "$RUNTIME_DIR/runner.pid"

    set +e
    wait "$zapret_pid"
    rc=$?
    set -e

    wait_for_runner "$zapret_pid"

    zapret_pid=""
    rm -f "$RUNTIME_DIR/runner.pid"

    [ "$shutdown_requested" -eq 1 ] && break

    if [ -e "$MAINTENANCE_FILE" ]; then
        log "Component update in progress, waiting..."
        continue
    fi

    if [ "$restart_requested" -eq 1 ]; then
        restart_requested=0
        log "Restarting zapret..."
        continue
    fi

    log "zapret exited with code $rc, restarting in 2 seconds..."
    sleep 2
done

log "Stopping zapret..."
if [ -n "$zapret_pid" ] && kill -0 "$zapret_pid" 2>/dev/null; then
    kill -TERM "$zapret_pid" 2>/dev/null || true
    wait "$zapret_pid" 2>/dev/null || true
fi

cleanup_network
wg_interface_delete "$WG_INTERFACE"
rm -f "$RUNTIME_DIR/runner.pid" "$RUNTIME_DIR/nfqws.pid" "$MAINTENANCE_FILE"

log "Stopped"
