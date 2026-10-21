# Blockbook + coin daemon launcher for Flux.
#
# Blockbook, RocksDB and every coin's config files are built into the image at
# a pinned upstream commit, so all instances of an app run the same code and a
# container starts in seconds instead of compiling for half an hour. Daemon
# binaries are still downloaded on first start, from the URL pinned in the
# coin config of that same commit (plus overrides.json).
ARG ZEBRA_VERSION=6.4.2

FROM zfnd/zebra:${ZEBRA_VERSION} AS zebra

# Same Debian as the runtime stage: zmq4 refuses to start when the libzmq it
# was built against differs from the one it runs with (4.3.4 vs 4.3.5).
FROM debian:13 AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BLOCKBOOK_REPO=https://github.com/trezor/blockbook.git
ARG BLOCKBOOK_COMMIT=3e6a90a287fb4e6d597978baf0aceeec985b5e41
ARG GOLANG_VERSION=go1.25.4
ARG GOLANG_SHA256=9fa5ffeda4170de60f67f3aa0f824e426421ba724c21e133c1e35d6159ca1bec
ARG ROCKSDB_VERSION=v9.10.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates git wget jq pkg-config libzmq3-dev libgflags-dev \
    libsnappy-dev zlib1g-dev libbz2-dev libzstd-dev liblz4-dev libjemalloc-dev && \
    rm -rf /var/lib/apt/lists/*

RUN cd /opt && wget -q https://dl.google.com/go/${GOLANG_VERSION}.linux-amd64.tar.gz && \
    echo "${GOLANG_SHA256}  ${GOLANG_VERSION}.linux-amd64.tar.gz" | sha256sum -c - && \
    tar xf ${GOLANG_VERSION}.linux-amd64.tar.gz && rm ${GOLANG_VERSION}.linux-amd64.tar.gz
ENV PATH=$PATH:/opt/go/bin GOPATH=/go GOTOOLCHAIN=local

# PORTABLE: Flux nodes run on every kind of CPU, and an instruction the build
# host has but the node lacks is a SIGILL at start.
RUN git clone -b ${ROCKSDB_VERSION} --depth 1 https://github.com/facebook/rocksdb.git /opt/rocksdb && \
    cd /opt/rocksdb && ROCKSDB_DISABLE_JEMALLOC=1 CFLAGS=-fPIC CXXFLAGS=-fPIC PORTABLE=1 \
    DISABLE_WARNING_AS_ERROR=1 make -j"$(nproc)" release && strip ldb

RUN git clone ${BLOCKBOOK_REPO} /src/blockbook && cd /src/blockbook && git checkout ${BLOCKBOOK_COMMIT}
WORKDIR /src/blockbook
COPY patches /tmp/patches
RUN for p in /tmp/patches/*.patch; do git apply --verbose "$p" || exit 1; done
RUN go mod download
# patches/0001 against a fake pruned bitcoind
RUN go test -count=1 -run 'Pruned' ./bchain/coins/btc/

ENV CGO_CFLAGS="-I/opt/rocksdb/include -O -D__BLST_PORTABLE__" \
    CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__"
RUN VERSION=$(jq -r .version configs/environ.json) && \
    export CGO_LDFLAGS="-L/opt/rocksdb -ldl -lrocksdb -lstdc++ -lm -lz -lbz2 -lsnappy -llz4 -lzstd $(gcc -print-file-name=libjemalloc_pic.a)" && \
    go build -o /out/blockbook -ldflags="-s -w \
      -X github.com/trezor/blockbook/common.version=${VERSION} \
      -X github.com/trezor/blockbook/common.gitcommit=$(git rev-parse --short HEAD) \
      -X github.com/trezor/blockbook/common.buildtime=$(date --iso-8601=seconds)"

# The config generator writes bitcoind's rpcauth line with
# build/scripts/rpcauth.py; without python3 it silently leaves the line out
# and the daemon refuses every RPC login.
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*

# Coin overrides (daemon versions we need ahead of upstream), then every coin's
# blockchaincfg.json and backend server.conf rendered with the container's
# paths, so nothing has to be compiled or fetched from GitHub at run time.
COPY overrides.json /tmp/overrides.json
RUN for coin in $(jq -r 'keys[]' /tmp/overrides.json); do \
      jq -s '.[0] * .[1]' configs/coins/$coin.json <(jq --arg c $coin '.[$c]' /tmp/overrides.json) > /tmp/c.json && \
      mv /tmp/c.json configs/coins/$coin.json; \
    done && \
    jq '.backend_install_path="/root" | .backend_data_path="/root"' configs/environ.json > /tmp/e.json && \
    mv /tmp/e.json configs/environ.json && \
    go build -o /tmp/generate build/templates/generate.go && \
    for f in configs/coins/*.json; do \
      coin=$(basename $f .json); rm -rf build/pkg-defs; \
      if BB_BUILD_ENV=prod /tmp/generate $coin > /dev/null 2>&1; then \
        mkdir -p /out/pkg/$coin; \
        cp build/pkg-defs/blockbook/blockchaincfg.json /out/pkg/$coin/ 2>/dev/null || true; \
        cp build/pkg-defs/backend/server.conf /out/pkg/$coin/ 2>/dev/null || true; \
      fi; \
    done && \
    echo "coins rendered: $(ls /out/pkg | wc -l)" && \
    test -f /out/pkg/flux/blockchaincfg.json && test -f /out/pkg/zcash/server.conf && \
    grep -q 'cache_dir = "/root/zcash/backend/zebra"' /out/pkg/zcash/server.conf && \
    grep -q '^rpcauth=rpc:' /out/pkg/bitcoin/server.conf && grep -q '^rpcauth=rpc:' /out/pkg/bitcoin_regtest/server.conf && \
    mkdir -p /out/configs && cp -r configs/coins /out/configs/ && cp configs/environ.json /out/configs/ && \
    cp -r static /out/static && \
    echo "blockbook $(jq -r .version configs/environ.json) $(git rev-parse --short HEAD)" > /out/VERSION

# zebrad (copied from zfnd/zebra, built on Debian 13) needs glibc 2.39 and
# CXXABI_1.3.15.
FROM debian:13-slim
# Links the ghcr.io package to this repository.
LABEL org.opencontainers.image.source=https://github.com/RunOnFlux/blockbook-docker
ENV DEBIAN_FRONTEND=noninteractive
# The daemons downloaded at start need only glibc (2.34 at most), libgcc_s,
# libstdc++ (fluxd) and libatomic (Bitcoin Cash Node 29), checked 2026-10-21.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq bc supervisor cron procps pv libarchive-tools unzip xz-utils \
    python3 libsnappy1v5 libzstd1 liblz4-1 libbz2-1.0 zlib1g libzmq5 libgflags2.2 libstdc++6 libatomic1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /out/blockbook /opt/blockbook/blockbook
COPY --from=build /out/configs /opt/blockbook/configs
# blockbook loads its explorer templates from ./static (blockbook.sh runs it from /opt/blockbook)
COPY --from=build /out/static /opt/blockbook/static
COPY --from=build /out/pkg /opt/blockbook/pkg
COPY --from=build /out/VERSION /opt/blockbook/VERSION
COPY --from=build /opt/rocksdb/ldb /opt/rocksdb/ldb
COPY --from=zebra /usr/local/bin/zebrad /usr/local/bin/zebrad
RUN /opt/blockbook/blockbook -help > /dev/null 2>&1; test $? -le 2 && zebrad --version

ENV HOME=/opt \
    RPC_USER=user \
    RPC_PASS=pass \
    BOOTSTRAP=0 \
    DAEMON=1 \
    CONFIG=AUTO \
    DAEMON_CONFIG=AUTO \
    PEER_BOOTSTRAP=1

COPY build.sh daemon.sh blockbook.sh check-health.sh consensus.sh utils.sh corruption.sh heal.sh snapshot.sh prune.sh snapshot_server.py /
RUN chmod 755 /*.sh /snapshot_server.py && mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
VOLUME /root
EXPOSE 1337
HEALTHCHECK --start-period=10m --interval=4m --retries=5 --timeout=40s CMD /check-health.sh
ENTRYPOINT ["/usr/bin/supervisord"]
