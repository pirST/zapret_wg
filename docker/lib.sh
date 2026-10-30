#!/usr/bin/env bash
# Shared helpers for the zapret-wg container scripts.

ADAPTER_DIR="${ADAPTER_DIR:-/opt/zapret-discord-youtube-linux}"
REPO_DIR="${REPO_DIR:-$ADAPTER_DIR/zapret-latest}"
NFQWS_PATH="${NFQWS_PATH:-$ADAPTER_DIR/nfqws}"
CUSTOM_STRATEGIES_DIR="${CUSTOM_STRATEGIES_DIR:-$ADAPTER_DIR/custom-strategies}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/zapret-wg}"
MAINTENANCE_FILE="${MAINTENANCE_FILE:-$RUNTIME_DIR/maintenance}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

detect_wan_iface() {
    local iface="${WAN_IFACE:-}"

    if [ -n "$iface" ] && [ "$iface" != "auto" ]; then
        ip link show "$iface" >/dev/null 2>&1 \
            || die "WAN interface '$iface' does not exist (check WAN_IFACE)"
        printf '%s\n' "$iface"
        return 0
    fi

    iface=$(ip -4 route show default 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

    [ -n "$iface" ] || die "Cannot detect the WAN interface (no default route). Set WAN_IFACE."
    printf '%s\n' "$iface"
}

# Turn ZAPRET_EXTRA_HOSTS into one domain per line.
# Accepts comma, semicolon and whitespace separators.
normalize_extra_hosts() {
    printf '%s\n' "${ZAPRET_EXTRA_HOSTS:-}" \
        | tr -s '[:space:],;' '\n' \
        | sed '/^[[:space:]]*$/d'
}
