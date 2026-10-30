FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG ADAPTER_REPO=https://github.com/Sergeydigl3/zapret-discord-youtube-linux.git
ARG DNSPROXY_VERSION=latest
# Changing this value invalidates the cache of the dnsproxy download layer.
# run.sh and the GitHub workflow bump it on every build, so "latest" is really
# resolved again instead of reusing an old cached layer.
ARG DNSPROXY_CACHE_BUST=""

ENV LANG=C.UTF-8 \
    ADAPTER_DIR=/opt/zapret-discord-youtube-linux \
    ZAPRET_STRATEGY=general_alt9.bat \
    ZAPRET_EXTRA_HOSTS="" \
    WG_CONFIG=/opt/config/wg0.conf \
    WG_INTERFACE=wg0 \
    WG_AUTOGEN=1 \
    WG_SERVER_ADDRESS=10.13.13.1/24 \
    WG_LISTEN_PORT=51820 \
    WG_MTU=1420 \
    WAN_IFACE=""

# Base shell utilities and all runtime dependencies.
# Dependencies are grouped by purpose, programs live in standard system paths.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        dnsutils \
        findutils \
        gawk \
        git \
        grep \
        gzip \
        iproute2 \
        ipset \
        iptables \
        iputils-ping \
        jq \
        kmod \
        less \
        libnetfilter-queue1 \
        libnfnetlink0 \
        nano \
        net-tools \
        nftables \
        procps \
        sed \
        tar \
        tcpdump \
        wget \
        wireguard-tools \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Dependency 1: zapret-discord-youtube adapter.
# Dependency 2: nfqws binary + Flowseal strategies, downloaded by the adapter
# into $ADAPTER_DIR/nfqws and $ADAPTER_DIR/zapret-latest.
RUN git clone --depth 1 "$ADAPTER_REPO" "$ADAPTER_DIR" \
    && cd "$ADAPTER_DIR" \
    && ./service.sh download-deps --default \
    && test -x "$ADAPTER_DIR/nfqws" \
    && test -d "$ADAPTER_DIR/zapret-latest/lists"

# Dependency 3: AdGuard dnsproxy. It receives plain DNS from WireGuard clients
# and forwards it over DoH through the WAN interface, where zapret desyncs it.
# By default the latest release is resolved at build time.  This layer is kept
# after the adapter so that DNSPROXY_CACHE_BUST only rebuilds the download and
# the following COPY, not the expensive adapter download.
RUN set -eux; \
    echo "dnsproxy build: ${DNSPROXY_CACHE_BUST}"; \
    version="$DNSPROXY_VERSION"; \
    if [ "$version" = "latest" ]; then \
        latest_url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/AdguardTeam/dnsproxy/releases/latest)"; \
        version="${latest_url##*/}"; \
    fi; \
    [ -n "$version" ] || { echo "Cannot determine the dnsproxy version" >&2; exit 1; }; \
    echo "dnsproxy version: $version"; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64|arm64|386) asset_arch="$arch" ;; \
        armhf) asset_arch="arm7" ;; \
        armel) asset_arch="arm6" ;; \
        *) echo "Unsupported architecture for dnsproxy: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/AdguardTeam/dnsproxy/releases/download/${version}/dnsproxy-linux-${asset_arch}-${version}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/dnsproxy.tar.gz; \
    tar -xzf /tmp/dnsproxy.tar.gz -C /tmp; \
    install -m 0755 "/tmp/linux-${asset_arch}/dnsproxy" /usr/local/bin/dnsproxy; \
    rm -rf /tmp/dnsproxy.tar.gz "/tmp/linux-${asset_arch}"; \
    dnsproxy --version

# Container-side scripts (entrypoint, zapret runner, update, helpers).
COPY docker/ /opt/zapret-wg/
RUN chmod +x /opt/zapret-wg/*.sh \
    && ln -sf /opt/zapret-wg/update.sh /usr/local/bin/zapret-wg-update \
    && ln -sf /opt/zapret-wg/genconfig.sh /usr/local/bin/wg-genconfig \
    && ln -sf /opt/zapret-wg/healthcheck.sh /usr/local/bin/zapret-wg-healthcheck

VOLUME ["/opt/config"]
EXPOSE 51820/udp 53/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
    CMD ["/usr/local/bin/zapret-wg-healthcheck"]

ENTRYPOINT ["/opt/zapret-wg/entrypoint.sh"]
