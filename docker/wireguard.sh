#!/usr/bin/env bash
# WireGuard and container networking helpers. Expects lib.sh to be sourced.

wg_interface_delete() {
    local iface="$1"

    if ip link show "$iface" >/dev/null 2>&1; then
        ip link delete "$iface" 2>/dev/null || true
    fi
}

wg_config_key_lines() {
    local key="$1" config="$2"

    grep -iE "^[[:space:]]*${key}[[:space:]]*=" "$config" 2>/dev/null || true
}

wg_config_addresses() {
    wg_config_key_lines Address "$1" \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | tr ',' '\n'
}

wg_config_allowed_ips() {
    wg_config_key_lines AllowedIPs "$1" \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | tr ',' '\n'
}

wg_config_mtu() {
    local config="$1" mtu

    mtu=$(wg_config_key_lines MTU "$config" \
        | head -n 1 \
        | sed 's/^[^=]*=[[:space:]]*//; s/#.*$//' \
        | tr -d '[:space:]')

    printf '%s\n' "${mtu:-${WG_MTU:-1420}}"
}

setup_wireguard() {
    local config="$1"
    local iface="$2"
    local addr cidr mtu stripped

    [ -f "$config" ] || die "WireGuard config not found: $config"
    command -v wg >/dev/null 2>&1 || die "wg is not installed"
    command -v wg-quick >/dev/null 2>&1 || die "wg-quick is not installed"

    wg_interface_delete "$iface"

    if ! ip link add dev "$iface" type wireguard 2>/dev/null; then
        die "Cannot create WireGuard interface '$iface'. The host kernel must support WireGuard (modprobe wireguard) and the container needs CAP_NET_ADMIN."
    fi

    mkdir -p "$RUNTIME_DIR"
    stripped=$(mktemp "$RUNTIME_DIR/wg-strip.XXXXXX")

    if ! wg-quick strip "$config" > "$stripped"; then
        rm -f "$stripped"
        wg_interface_delete "$iface"
        die "Failed to parse WireGuard config: $config"
    fi

    if ! wg setconf "$iface" "$stripped"; then
        rm -f "$stripped"
        wg_interface_delete "$iface"
        die "Failed to apply WireGuard config: $config"
    fi

    rm -f "$stripped"

    while IFS= read -r addr; do
        addr="${addr%%#*}"
        addr=$(printf '%s' "$addr" | xargs)
        [ -n "$addr" ] || continue
        ip addr add "$addr" dev "$iface" 2>/dev/null \
            || warn "Could not add address $addr to $iface"
    done < <(wg_config_addresses "$config")

    mtu=$(wg_config_mtu "$config")
    ip link set dev "$iface" mtu "$mtu" up

    # Install routes for peer subnets. Default routes are intentionally skipped:
    # this container is a VPN gateway, not a WireGuard client.
    while IFS= read -r cidr; do
        cidr="${cidr%%#*}"
        cidr=$(printf '%s' "$cidr" | xargs)
        [ -n "$cidr" ] || continue
        case "$cidr" in
            0.0.0.0/0|::/0) continue ;;
            *:*) ip -6 route replace "$cidr" dev "$iface" 2>/dev/null || true ;;
            *)   ip route replace "$cidr" dev "$iface" 2>/dev/null || true ;;
        esac
    done < <(wg_config_allowed_ips "$config")

    log "WireGuard $iface is up (MTU $mtu, listen port $(wg show "$iface" listen-port))"
}

setup_forwarding() {
    sysctl -qw net.ipv4.ip_forward=1 2>/dev/null \
        || warn "Could not enable IPv4 forwarding inside the container; run with --sysctl net.ipv4.ip_forward=1"
    sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null || true

    # Router mode: nfqws fake packets with bad checksums must survive NAT.
    # Recommended by the zapret documentation for router installations.
    sysctl -qw net.netfilter.nf_conntrack_checksum=0 2>/dev/null \
        || warn "Could not disable nf_conntrack checksum validation; badsum-based strategies may not work through NAT"

    # Accept out-of-window TCP packets (badseq fooling) instead of marking
    # them INVALID and dropping/not translating them in NAT.
    sysctl -qw net.netfilter.nf_conntrack_tcp_be_liberal=1 2>/dev/null \
        || warn "Could not enable liberal TCP conntrack; badseq-based strategies may be affected by NAT"
}

setup_nat() {
    local wan="$1"

    # NAT everything leaving the WAN interface. This covers both forwarded
    # WireGuard traffic and locally generated nfqws fake packets (they carry
    # the original client source address and must be masqueraded too).
    nft delete table ip zapret_wg_nat 2>/dev/null || true
    nft add table ip zapret_wg_nat || die "Cannot create nftables NAT table"
    nft 'add chain ip zapret_wg_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' \
        || die "Cannot create nftables postrouting chain"
    nft add rule ip zapret_wg_nat postrouting oifname "$wan" masquerade \
        || die "Cannot add masquerade rule"
    log "IPv4 NAT enabled on $wan"

    # IPv6 is best effort: most setups here only use IPv4.
    nft delete table ip6 zapret_wg_nat 2>/dev/null || true
    if nft add table ip6 zapret_wg_nat 2>/dev/null; then
        if nft 'add chain ip6 zapret_wg_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null; then
            nft add rule ip6 zapret_wg_nat postrouting oifname "$wan" masquerade 2>/dev/null \
                || warn "Could not add IPv6 masquerade rule"
        else
            warn "IPv6 NAT is not available; IPv6 traffic will not be masqueraded"
        fi
    fi
}

setup_mss_clamp() {
    command -v iptables >/dev/null 2>&1 || return 0

    if iptables -w 5 -t mangle -C FORWARD \
        -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        return 0
    fi

    iptables -w 5 -t mangle -A FORWARD \
        -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || warn "Could not add TCP MSS clamp rule"
}

cleanup_network() {
    nft delete table ip zapret_wg_nat 2>/dev/null || true
    nft delete table ip6 zapret_wg_nat 2>/dev/null || true

    if command -v iptables >/dev/null 2>&1; then
        iptables -w 5 -t mangle -D FORWARD \
            -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
}
