FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN set -e; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        libssl-dev \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . .

RUN make -j"$(nproc)"

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN set -e; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        libssl3 \
        curl \
        tini \
        iproute2 \
        zlib1g; \
    rm -rf /var/lib/apt/lists/*; \
    useradd -r -s /usr/sbin/nologin mtproxy; \
    mkdir -p /etc/mtproxy; \
    chown -R mtproxy:mtproxy /etc/mtproxy;

COPY --from=builder /build/objs/bin/mtproto-proxy /usr/bin/mtproto-proxy
COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh

EXPOSE 443 8888

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD curl -f http://localhost:${MT_STATS_PORT:-8888}/stats || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/docker-entrypoint.sh"]
