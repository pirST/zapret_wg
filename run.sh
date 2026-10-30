#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-zapret-wg:latest}"
NAME="${NAME:-zapret-wg}"
CONFIG_DIR="${CONFIG_DIR:-$PWD/config}"
ZAPRET_STRATEGY="${ZAPRET_STRATEGY:-general_alt9.bat}"
ZAPRET_EXTRA_HOSTS="${ZAPRET_EXTRA_HOSTS:-}"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_CLIENT_NAME="${WG_CLIENT_NAME:-client1}"
WG_CLIENT_ADDRESS="${WG_CLIENT_ADDRESS:-}"
WG_CLIENT_DNS="${WG_CLIENT_DNS-1.1.1.1}"
WG_CLIENT_ENDPOINT="${WG_CLIENT_ENDPOINT:-}"

mkdir -p "$CONFIG_DIR"

if docker container inspect "$NAME" >/dev/null 2>&1; then
    echo "Container '$NAME' already exists. Remove it first: docker rm -f $NAME" >&2
    exit 1
fi

docker build -t "$IMAGE" .

docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.netfilter.nf_conntrack_checksum=0 \
    --sysctl net.netfilter.nf_conntrack_tcp_be_liberal=1 \
    -p "${WG_LISTEN_PORT}:${WG_LISTEN_PORT}/udp" \
    -v "${CONFIG_DIR}:/opt/config" \
    -e "ZAPRET_STRATEGY=${ZAPRET_STRATEGY}" \
    -e "ZAPRET_EXTRA_HOSTS=${ZAPRET_EXTRA_HOSTS}" \
    -e "WG_LISTEN_PORT=${WG_LISTEN_PORT}" \
    -e "WG_CLIENT_NAME=${WG_CLIENT_NAME}" \
    -e "WG_CLIENT_ADDRESS=${WG_CLIENT_ADDRESS}" \
    -e "WG_CLIENT_DNS=${WG_CLIENT_DNS}" \
    -e "WG_CLIENT_ENDPOINT=${WG_CLIENT_ENDPOINT}" \
    "$IMAGE"

echo
echo "Container '$NAME' started."
echo "Logs:              docker logs -f $NAME"
echo "Shell:             docker exec -it $NAME bash"
echo "Server public key: docker exec $NAME wg show wg0 public-key"
echo

# Give the container a moment to generate keys and start WireGuard.
for _ in $(seq 1 20); do
    if docker exec "$NAME" wg show wg0 public-key >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

docker logs --tail 40 "$NAME" 2>/dev/null || true
