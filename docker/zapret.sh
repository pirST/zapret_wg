#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
# shellcheck source=docker/lib.sh
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Adapter libraries (zapret-discord-youtube-linux)
# ---------------------------------------------------------------------------
[ -d "$REPO_DIR" ] || die "Strategies directory not found: $REPO_DIR (re-run zapret-wg-update or rebuild the image)"
[ -x "$NFQWS_PATH" ] || die "nfqws not found: $NFQWS_PATH (re-run zapret-wg-update or rebuild the image)"
[ -n "${WAN_IFACE:-}" ] || die "WAN_IFACE is not set"

export BASE_DIR="$ADAPTER_DIR"
export REPO_DIR CUSTOM_STRATEGIES_DIR NFQWS_PATH

# shellcheck disable=SC1091
source "$ADAPTER_DIR/src/lib/elevate.sh"
# shellcheck disable=SC1091
source "$ADAPTER_DIR/src/lib/common.sh"
# shellcheck disable=SC1091
source "$ADAPTER_DIR/src/lib/firewall.sh"

export FIREWALL_BACKEND="nftables"

case "${ZAPRET_STRATEGY:-}" in
    */*) die "ZAPRET_STRATEGY must be a strategy file name, not a path" ;;
esac

strategy=$(normalize_strategy "${ZAPRET_STRATEGY:-general_alt9.bat}") || {
    log "Available strategies:"
    get_strategies | sed 's/^/  /'
    die "Strategy '${ZAPRET_STRATEGY}' was not found"
}

strategy_path=$(get_strategy_path "$strategy")
[ -n "$strategy_path" ] || die "Cannot resolve strategy file: $strategy"

export USE_GAME_FILTER=false
export USE_GAME_FILTER_TCP=false
export USE_GAME_FILTER_UDP=false

parse_bat_file "$strategy_path"

[ -n "${tcp_ports:-}" ] || die "Strategy $strategy does not define TCP ports"
[ -n "${udp_ports:-}" ] || die "Strategy $strategy does not define UDP ports"

# ---------------------------------------------------------------------------
# ZAPRET_EXTRA_HOSTS: add custom domains to every hostlist-based filter.
# ---------------------------------------------------------------------------
EXTRA_HOSTS_FILE="$REPO_DIR/lists/list-zapret-wg-extra.txt"
mkdir -p "$REPO_DIR/lists"
normalize_extra_hosts > "$EXTRA_HOSTS_FILE"
chmod 644 "$EXTRA_HOSTS_FILE"

EXTRA_HOSTS_APPLIED=0

inject_extra_hostlist() {
    local file="$1" i params

    for i in "${!nfqws_params[@]}"; do
        params="${nfqws_params[$i]}"

        # Extend only the strategy's general profiles. Adding the list to
        # every hostlist would change profile matching order (Google/Discord
        # specific profiles could start handling the extra domains).
        if [[ "$params" =~ --hostlist=[^[:space:]]*list-general ]]; then
            if [[ "$params" =~ ^(.*)[[:space:]]--new[[:space:]]*$ ]]; then
                # shellcheck disable=SC2004 # bash treats array subscripts as arithmetic
                nfqws_params[$i]="${BASH_REMATCH[1]} --hostlist=$file --new"
            else
                # shellcheck disable=SC2004 # bash treats array subscripts as arithmetic
                nfqws_params[$i]="$params --hostlist=$file"
            fi
            EXTRA_HOSTS_APPLIED=$((EXTRA_HOSTS_APPLIED + 1))
        fi
    done
}

if [ -s "$EXTRA_HOSTS_FILE" ]; then
    inject_extra_hostlist "$EXTRA_HOSTS_FILE"
    log "ZAPRET_EXTRA_HOSTS: $(wc -l < "$EXTRA_HOSTS_FILE") domain(s), applied to $EXTRA_HOSTS_APPLIED general profile(s)"
    if [ "$EXTRA_HOSTS_APPLIED" -eq 0 ]; then
        warn "Strategy $strategy has no general hostlist profile; ZAPRET_EXTRA_HOSTS has no effect"
    fi
else
    rm -f "$EXTRA_HOSTS_FILE"
fi

# ---------------------------------------------------------------------------
# nfqws arguments
# ---------------------------------------------------------------------------
log "Strategy: $strategy (TCP: $tcp_ports; UDP: $udp_ports)"

build_nfqws_args() {
    local params
    local -a words

    NFQWS_ARGS=("$NFQWS_PATH" "--dpi-desync-fwmark=$NFT_MARK" "--qnum=$NFT_QUEUE_NUM")

    for params in "${nfqws_params[@]}"; do
        words=()
        read -r -a words <<< "$params"
        NFQWS_ARGS+=("${words[@]}")
    done
}

build_nfqws_args

cd "$REPO_DIR" || die "Cannot change directory to $REPO_DIR"

if [ "${ZAPRET_DEBUG:-0}" = "1" ]; then
    log "nfqws command: $(printf '%q ' "${NFQWS_ARGS[@]}")"
fi

if [ "${ZAPRET_DRY_RUN:-0}" = "1" ]; then
    log "Dry run: verifying nfqws parameters"
    "${NFQWS_ARGS[@]}" --dry-run
    exit $?
fi

# ---------------------------------------------------------------------------
# Firewall and nfqws
# ---------------------------------------------------------------------------
NFQWS_PID=""
CLEANED=0

# shellcheck disable=SC2317 # cleanup is called from the EXIT/TERM/INT traps
cleanup() {
    [ "$CLEANED" -eq 1 ] && return 0
    CLEANED=1
    trap - EXIT TERM INT

    if [ -n "${NFQWS_PID:-}" ] && kill -0 "$NFQWS_PID" 2>/dev/null; then
        kill -TERM "$NFQWS_PID" 2>/dev/null || true
        wait "$NFQWS_PID" 2>/dev/null || true
    fi

    rm -f "$RUNTIME_DIR/nfqws.pid"
    firewall_clear || true
}

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Do not send the outer WireGuard UDP packets through nfqws.
add_wg_queue_exclusion() {
    local port="${1:-}"

    [ -n "$port" ] && [ "$port" != "0" ] || return 0

    if ! nft list chain inet zapretunix post >/dev/null 2>&1; then
        warn "nftables chain inet zapretunix post not found; WireGuard port is not excluded"
        return 0
    fi

    nft insert rule inet zapretunix post udp dport "$port" accept 2>/dev/null \
        || warn "Could not exclude WireGuard UDP dport $port from NFQUEUE"
    nft insert rule inet zapretunix post udp sport "$port" accept 2>/dev/null \
        || warn "Could not exclude WireGuard UDP sport $port from NFQUEUE"

    log "WireGuard UDP port $port is excluded from NFQUEUE"
}

log "Applying nftables rules on WAN interface: $WAN_IFACE"

pkill -x nfqws 2>/dev/null || true

firewall_setup "$tcp_ports" "$udp_ports" "$WAN_IFACE"
add_wg_queue_exclusion "${WG_LISTEN_PORT:-}"

log "Starting nfqws..."
"${NFQWS_ARGS[@]}" &
NFQWS_PID=$!
printf '%s\n' "$NFQWS_PID" > "$RUNTIME_DIR/nfqws.pid"

set +e
wait "$NFQWS_PID"
rc=$?
set -e

NFQWS_PID=""
log "nfqws exited with code $rc"
exit "$rc"
