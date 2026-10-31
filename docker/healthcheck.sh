#!/usr/bin/env bash
set -Eeuo pipefail

IFACE="wg0"

ip link show "$IFACE" >/dev/null 2>&1 || exit 1
wg show "$IFACE" >/dev/null 2>&1 || exit 1
pgrep -x nfqws >/dev/null 2>&1 || exit 1
if [ -n "${DNSPROXY_CONF:-}" ]; then
    pgrep -x dnsproxy >/dev/null 2>&1 || exit 1
fi
nft list table inet zapretunix >/dev/null 2>&1 || exit 1

exit 0
