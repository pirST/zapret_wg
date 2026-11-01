#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-zapret-wg:latest}"
NAME="${NAME:-zapret-wg}"
CONFIG_DIR="${CONFIG_DIR:-$PWD/config}"
ZAPRET_STRATEGY="${ZAPRET_STRATEGY:-general_alt9.bat}"
ZAPRET_EXTRA_HOSTS="${ZAPRET_EXTRA_HOSTS:-}"
DNS_PORT="${DNS_PORT:-53}"
DNSPROXY_CONF="${DNSPROXY_CONF:-}"
WG_CLIENT_NAME="${WG_CLIENT_NAME:-client1}"
WG_SERVER_ADDRESS="${WG_SERVER_ADDRESS:-}"
WG_CLIENT_ADDRESS="${WG_CLIENT_ADDRESS:-}"
WG_CLIENT_ENDPOINT="${WG_CLIENT_ENDPOINT:-}"

mkdir -p "$CONFIG_DIR"

if docker container inspect "$NAME" >/dev/null 2>&1; then
    echo "Container '$NAME' already exists. Remove it first: docker rm -f $NAME" >&2
    exit 1
fi

# DNSPROXY_CACHE_BUST forces the dnsproxy download layer to re-run on every
# build so the latest release is picked up.
docker build \
    --build-arg "DNSPROXY_CACHE_BUST=$(date +%s)" \
    -t "$IMAGE" .

docker_args=(
    -d
    --name "$NAME"
    --restart unless-stopped
    --cap-add NET_ADMIN
    --cap-add NET_RAW
    --sysctl net.ipv4.ip_forward=1
    --sysctl net.netfilter.nf_conntrack_checksum=0
    --sysctl net.netfilter.nf_conntrack_tcp_be_liberal=1
    -p "51820:51820/udp"
    -v "${CONFIG_DIR}:/opt/config"
    -e "ZAPRET_STRATEGY=${ZAPRET_STRATEGY}"
    -e "ZAPRET_EXTRA_HOSTS=${ZAPRET_EXTRA_HOSTS}"
    -e "DNSPROXY_CONF=${DNSPROXY_CONF}"
    -e "WG_CLIENT_NAME=${WG_CLIENT_NAME}"
    -e "WG_SERVER_ADDRESS=${WG_SERVER_ADDRESS}"
    -e "WG_CLIENT_ADDRESS=${WG_CLIENT_ADDRESS}"
    -e "WG_CLIENT_ENDPOINT=${WG_CLIENT_ENDPOINT}"
)

if [ -n "$DNSPROXY_CONF" ]; then
    docker_args+=(-p "${DNS_PORT}:53/udp")
fi

# Do not pass WG_CLIENT_DNS when it is unset: genconfig.sh then picks the
# dnsproxy address (or 1.1.1.1) automatically.  An explicitly empty value
# selects the public 1.1.1.1 fallback.
if [ -n "${WG_CLIENT_DNS+x}" ]; then
    docker_args+=(-e "WG_CLIENT_DNS=${WG_CLIENT_DNS}")
fi

docker run "${docker_args[@]}" "$IMAGE"

echo
echo "Container '$NAME' started."
echo "Logs:              docker logs -f $NAME"
echo "Shell:             docker exec -it $NAME bash"
echo "Server public key: docker exec $NAME wg show wg0 public-key"
if [ -n "$DNSPROXY_CONF" ]; then
    echo "DNS on host:       dig @127.0.0.1 -p $DNS_PORT example.com"
fi
echo

# Give the container a moment to generate keys and start WireGuard.
for _ in $(seq 1 20); do
    if docker exec "$NAME" wg show wg0 public-key >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

docker logs --tail 40 "$NAME" 2>/dev/null || true
