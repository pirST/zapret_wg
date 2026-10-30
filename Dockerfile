FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG ADAPTER_REPO=https://github.com/Sergeydigl3/zapret-discord-youtube-linux.git

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

# Dependency 1: zapret-discord-youtube-linux adapter.
# Dependency 2: nfqws binary + Flowseal strategies, downloaded by the adapter
# into $ADAPTER_DIR/nfqws and $ADAPTER_DIR/zapret-latest.
RUN git clone --depth 1 "$ADAPTER_REPO" "$ADAPTER_DIR" \
    && cd "$ADAPTER_DIR" \
    && ./service.sh download-deps --default \
    && test -x "$ADAPTER_DIR/nfqws" \
    && test -d "$ADAPTER_DIR/zapret-latest/lists"

# Container-side scripts (entrypoint, zapret runner, update, helpers).
COPY docker/ /opt/zapret-wg/
RUN chmod +x /opt/zapret-wg/*.sh \
    && ln -sf /opt/zapret-wg/update.sh /usr/local/bin/zapret-wg-update \
    && ln -sf /opt/zapret-wg/genconfig.sh /usr/local/bin/wg-genconfig \
    && ln -sf /opt/zapret-wg/healthcheck.sh /usr/local/bin/zapret-wg-healthcheck

VOLUME ["/opt/config"]
EXPOSE 51820/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
    CMD ["/usr/local/bin/zapret-wg-healthcheck"]

ENTRYPOINT ["/opt/zapret-wg/entrypoint.sh"]
