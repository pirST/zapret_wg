#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
# shellcheck source=docker/lib.sh
source "$SCRIPT_DIR/lib.sh"

CONFIG="${1:-/opt/config/wg0.conf}"
CONFIG_DIR="$(dirname "$CONFIG")"
ADDRESS="10.13.13.1/24"
PORT="51820"
MTU="${WG_MTU:-1420}"
CLIENT_NAME="${WG_CLIENT_NAME:-client1}"

# Client DNS:
#   * non-empty WG_CLIENT_DNS wins;
#   * explicitly empty WG_CLIENT_DNS -> public fallback (1.1.1.1);
#   * unset -> dnsproxy address if it is running, otherwise 1.1.1.1.
if [ -n "${WG_CLIENT_DNS:-}" ]; then
    CLIENT_DNS="$WG_CLIENT_DNS"
elif [ -n "${WG_CLIENT_DNS+x}" ]; then
    CLIENT_DNS="1.1.1.1"
elif dnsproxy_running; then
    CLIENT_DNS="$(dnsproxy_client_ip "${ADDRESS%%/*}")"
else
    CLIENT_DNS="1.1.1.1"
fi

# Derive the first client address from the server address (10.13.13.1 ->
# 10.13.13.2). Fall back to the default subnet for unusual addresses.
default_client_address() {
    local server_host="${1%%/*}" last

    case "$server_host" in
        *.*.*.*)
            last="${server_host##*.}"
            case "$last" in
                ''|*[!0-9]*) ;;
                *)
                    if [ "$last" -lt 254 ]; then
                        printf '%s.%s/32\n' "${server_host%.*}" "$((last + 1))"
                        return 0
                    fi
                    ;;
            esac
            ;;
    esac

    printf '10.13.13.2/32\n'
}

CLIENT_ADDRESS="${WG_CLIENT_ADDRESS:-$(default_client_address "$ADDRESS")}"
CLIENT_ENDPOINT="${WG_CLIENT_ENDPOINT:-<SERVER_PUBLIC_IP>:$PORT}"

if [ -e "$CONFIG" ] && [ -s "$CONFIG" ]; then
    die "WireGuard config already exists: $CONFIG"
fi

command -v wg >/dev/null 2>&1 || die "wg is not installed"

CLIENT_CONFIG="$CONFIG_DIR/clients/$CLIENT_NAME.conf"
if [ -e "$CLIENT_CONFIG" ] && [ -s "$CLIENT_CONFIG" ]; then
    die "Client config already exists: $CLIENT_CONFIG"
fi

umask 077
mkdir -p "$CONFIG_DIR/clients"

private_key=$(wg genkey)
public_key=$(printf '%s\n' "$private_key" | wg pubkey)

client_private_key=$(wg genkey)
client_public_key=$(printf '%s\n' "$client_private_key" | wg pubkey)
preshared_key=$(wg genpsk)

cat > "$CONFIG" <<EOF
[Interface]
Address = $ADDRESS
ListenPort = $PORT
PrivateKey = $private_key
MTU = $MTU

[Peer]
# zapret-wg auto-generated client: $CLIENT_NAME
PublicKey = $client_public_key
PresharedKey = $preshared_key
AllowedIPs = $CLIENT_ADDRESS
EOF

chmod 600 "$CONFIG"

{
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$client_private_key"
    printf 'Address = %s\n' "$CLIENT_ADDRESS"
    if [ -n "$CLIENT_DNS" ]; then
        printf 'DNS = %s\n' "$CLIENT_DNS"
    fi
    printf 'MTU = %s\n' "$MTU"
    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "$public_key"
    printf 'PresharedKey = %s\n' "$preshared_key"
    printf 'Endpoint = %s\n' "$CLIENT_ENDPOINT"
    printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
    printf 'PersistentKeepalive = 25\n'
} > "$CLIENT_CONFIG"

chmod 600 "$CLIENT_CONFIG"

printf '\nWireGuard config created: %s\n' "$CONFIG"
printf 'Client config created:    %s\n\n' "$CLIENT_CONFIG"
printf 'Server public key:\n  %s\n\n' "$public_key"
case "$CLIENT_ENDPOINT" in
    *'<'*)
        printf 'Replace <SERVER_PUBLIC_IP> with the public IP or domain of this server,\n'
        printf 'then import the client config into the WireGuard app.\n\n'
        ;;
esac
