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

export WG_AUTOGEN="${WG_AUTOGEN:-1}"
export ZAPRET_STRATEGY="${ZAPRET_STRATEGY:-general_alt9.bat}"
export ZAPRET_EXTRA_HOSTS="${ZAPRET_EXTRA_HOSTS:-}"
export DNSPROXY_CONF="${DNSPROXY_CONF:-}"

mkdir -p "$RUNTIME_DIR" /opt/config
rm -f "$MAINTENANCE_FILE" "$RUNTIME_DIR/runner.pid" "$RUNTIME_DIR/nfqws.pid" "$RUNTIME_DIR/dnsproxy.pid"

zapret_pid=""
dnsproxy_pid=""
restart_requested=0
shutdown_requested=0

on_term() {
    shutdown_requested=1
    if [ -n "$zapret_pid" ] && kill -0 "$zapret_pid" 2>/dev/null; then
        kill -TERM "$zapret_pid" 2>/dev/null || true
    fi
    if [ -n "$dnsproxy_pid" ] && kill -0 "$dnsproxy_pid" 2>/dev/null; then
        kill -TERM "$dnsproxy_pid" 2>/dev/null || true
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

# Start dnsproxy before generating client configs: genconfig.sh uses its
# real state to decide whether clients get the dnsproxy IP or the container
# resolver.
if dnsproxy_enabled; then
    log "Starting DNS proxy..."
    "$SCRIPT_DIR/dnsproxy.sh" &
    dnsproxy_pid=$!

    for _ in $(seq 1 20); do
        dnsproxy_running && break
        kill -0 "$dnsproxy_pid" 2>/dev/null || break
        sleep 0.1
    done

    if dnsproxy_running; then
        log "dnsproxy is running"
    else
        warn "dnsproxy is not running; WireGuard client DNS will use the container resolver"
    fi
else
    log "DNSPROXY_CONF is empty, DNS proxy disabled"
fi

if [ ! -s /opt/config/wg0.conf ]; then
    if [ "$WG_AUTOGEN" = "1" ]; then
        log "WireGuard config not found, generating a new one: /opt/config/wg0.conf"
        "$SCRIPT_DIR/genconfig.sh" /opt/config/wg0.conf
    else
        die "WireGuard config not found: /opt/config/wg0.conf (set WG_AUTOGEN=1 to generate one)"
    fi
fi

wan_iface="$(detect_wan_iface)"
log "WAN interface: $wan_iface"

setup_forwarding
setup_wireguard /opt/config/wg0.conf wg0

setup_nat "$wan_iface"
setup_mss_clamp

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

log "Stopping dnsproxy..."
if [ -n "$dnsproxy_pid" ] && kill -0 "$dnsproxy_pid" 2>/dev/null; then
    kill -TERM "$dnsproxy_pid" 2>/dev/null || true
    wait "$dnsproxy_pid" 2>/dev/null || true
fi

dnsproxy_pid=""
cleanup_network
wg_interface_delete wg0
rm -f "$RUNTIME_DIR/runner.pid" "$RUNTIME_DIR/nfqws.pid" "$RUNTIME_DIR/dnsproxy.pid" "$MAINTENANCE_FILE"

log "Stopped"
