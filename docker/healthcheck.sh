#!/usr/bin/env bash
set -Eeuo pipefail

IFACE="${WG_INTERFACE:-wg0}"

ip link show "$IFACE" >/dev/null 2>&1 || exit 1
wg show "$IFACE" >/dev/null 2>&1 || exit 1
pgrep -x nfqws >/dev/null 2>&1 || exit 1
nft list table inet zapretunix >/dev/null 2>&1 || exit 1

exit 0
