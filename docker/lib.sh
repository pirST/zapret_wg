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
    local iface

    iface=$(ip -4 route show default 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

    [ -n "$iface" ] || die "Cannot detect the WAN interface (no default route)."
    printf '%s\n' "$iface"
}

# Turn ZAPRET_EXTRA_HOSTS into one entry per line.
# Accepts comma, semicolon and whitespace separators.
normalize_extra_hosts() {
    printf '%s\n' "${ZAPRET_EXTRA_HOSTS:-}" \
        | tr -s '[:space:],;' '\n' \
        | sed '/^[[:space:]]*$/d'
}

# Return true for IPv4 addresses and IPv4 CIDRs.
is_ipv4_or_cidr() {
    local entry="$1" ip prefix octet

    case "$entry" in
        */*)
            ip="${entry%/*}"
            prefix="${entry##*/}"
            [ -n "$prefix" ] || return 1
            ;;
        *)
            ip="$entry"
            prefix=""
            ;;
    esac

    if [ -n "$prefix" ]; then
        case "$prefix" in *[!0-9]*) return 1 ;; esac
        (( 10#$prefix <= 32 )) || return 1
    fi

    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

# Return true for IPv6 addresses and IPv6 CIDRs.  Hostnames cannot contain
# colons, so a colon plus hex characters is enough to classify the entry.
is_ipv6_or_cidr() {
    local entry="$1" ip prefix

    case "$entry" in
        */*)
            ip="${entry%/*}"
            prefix="${entry##*/}"
            [ -n "$prefix" ] || return 1
            ;;
        *)
            ip="$entry"
            prefix=""
            ;;
    esac

    if [ -n "$prefix" ]; then
        case "$prefix" in *[!0-9]*) return 1 ;; esac
        (( 10#$prefix <= 128 )) || return 1
    fi

    case "$ip" in
        *:*) ;;
        *) return 1 ;;
    esac

    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
}

is_ip_or_cidr() {
    is_ipv4_or_cidr "$1" || is_ipv6_or_cidr "$1"
}

# ZAPRET_EXTRA_HOSTS split into domain names and IP/CIDR entries.
normalize_extra_domains() {
    local entry

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if ! is_ip_or_cidr "$entry"; then
            printf '%s\n' "$entry"
        fi
    done < <(normalize_extra_hosts)
}

normalize_extra_ips() {
    local entry

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if is_ip_or_cidr "$entry"; then
            printf '%s\n' "$entry"
        fi
    done < <(normalize_extra_hosts)
}

# Build an IP-only copy of an nfqws profile.  nfqws treats --ipset as a hard
# filter, so it cannot be added to a profile with --hostlist: the profile would
# then require both the destination IP and the hostname to match.  Instead the
# hostlist options are removed and the clone is filtered only by the extra IPs.
build_ip_profile() {
    local params="$1" ipfile="$2" suffix="" word
    local -a words out

    if [[ "$params" =~ ^(.*)[[:space:]]--new[[:space:]]*$ ]]; then
        params="${BASH_REMATCH[1]}"
        suffix="--new"
    fi

    read -r -a words <<< "$params"
    for word in "${words[@]}"; do
        case "$word" in
            --hostlist=*|--hostlist-domains=*|--hostlist-exclude=*|--hostlist-exclude-domains=*|--hostlist-auto=*|--hostlist-auto-fail-threshold=*|--hostlist-auto-fail-time=*|--hostlist-auto-retrans-threshold=*|--hostlist-auto-debug=*|--ipset=*|--ipset-ip=*)
                continue
                ;;
        esac
        out+=("$word")
    done

    out+=("--ipset=$ipfile")
    [ -n "$suffix" ] && out+=("$suffix")
    printf '%s\n' "${out[*]}"
}

# Insert an IP-only clone after every general hostlist profile.
# Expects and updates the global nfqws_params array.
inject_extra_ipset() {
    local file="$1" i params clone
    local -a result=()

    EXTRA_IPSET_APPLIED=0

    for i in "${!nfqws_params[@]}"; do
        params="${nfqws_params[$i]}"

        if [[ "$params" =~ --hostlist=[^[:space:]]*list-general ]]; then
            clone="$(build_ip_profile "$params" "$file")"

            if [[ "$params" =~ ^(.*)[[:space:]]--new[[:space:]]*$ ]]; then
                result+=("$params")
            else
                # The parent is the last profile, so terminate it before the
                # inserted IP clone.
                result+=("$params --new")
            fi

            result+=("$clone")
            EXTRA_IPSET_APPLIED=$((EXTRA_IPSET_APPLIED + 1))
        else
            result+=("$params")
        fi
    done

    nfqws_params=("${result[@]}")
}

# dnsproxy is enabled only when DNSPROXY_CONF contains command-line flags.
dnsproxy_enabled() {
    [ -n "${DNSPROXY_CONF:-}" ]
}

# Check whether the dnsproxy supervisor has a live child process.
dnsproxy_running() {
    local pidfile="$RUNTIME_DIR/dnsproxy.pid" pid

    [ -s "$pidfile" ] || return 1
    read -r pid < "$pidfile" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Print hostnames of DoH upstreams from the DNSPROXY_CONF flags.  They are
# added to the strategy's general hostlist so nfqws desyncs TLS handshakes
# to those servers as well.
dnsproxy_doh_hosts() {
    local conf="${DNSPROXY_CONF:-}"

    [ -n "$conf" ] || return 0

    printf '%s\n' "$conf" \
        | grep -oE "https://[^\"'[:space:],]+" \
        | sed -E 's#^https://([^/:]+).*#\1#' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/\.$//' \
        | grep -E '^[a-z0-9.-]+$' \
        | grep -E '[a-z]' \
        | sort -u \
        || true
}

# Print the IP that WireGuard clients should use to reach dnsproxy.  A
# concrete -l/--listen address wins, otherwise the fallback (the WireGuard
# server address) is used.
dnsproxy_client_ip() {
    local fallback="${1:-}" token value conf
    local -a args
    local i

    conf="${DNSPROXY_CONF:-}"
    conf="${conf//$'\n'/ }"
    read -r -a args <<< "$conf"

    for ((i = 0; i < ${#args[@]}; i++)); do
        token="${args[i]}"
        case "$token" in
            -l|--listen)
                i=$((i + 1))
                value="${args[i]:-}"
                ;;
            -l?*)
                value="${token#-l}"
                value="${value#=}"
                ;;
            --listen=*)
                value="${token#*=}"
                ;;
            *)
                continue
                ;;
        esac

        case "$value" in
            ''|0.0.0.0|::|127.*|::1|localhost) continue ;;
        esac

        printf '%s\n' "$value"
        return 0
    done

    printf '%s\n' "$fallback"
}

# Write the DoH hostnames to a runtime file consumed by zapret.sh.
write_dnsproxy_hosts() {
    local out="$RUNTIME_DIR/dnsproxy-hosts.txt"

    mkdir -p "$RUNTIME_DIR"

    if ! dnsproxy_enabled; then
        rm -f "$out"
        return 0
    fi

    dnsproxy_doh_hosts > "$out"
}
