FROM debian:11
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
  apt-get upgrade -y && \
  apt-get install -y git wget autoconf automake jq bc supervisor procps curl \
  graphviz libsnappy-dev libzstd-dev zlib1g-dev libbz2-dev liblz4-dev libunwind-dev \
  bsdmainutils build-essential g++-multilib libc6-dev pv libarchive-tools cron unzip libtool \
  m4 ncurses-dev pkg-config python3 python3-zmq zlib1g-dev libzmq3-dev

ENV BLOCKBOOKGIT_URL=${BLOCKBOOKGIT_URL:-https://github.com/trezor/blockbook.git}
ENV TAG=${TAG:-master}
ENV RPC_USER=${RPC_USER:-user}
ENV RPC_PASS=${RPC_PASS:-pass}
ENV HOME=/opt
ENV BOOTSTRAP=${BOOTSTRAP:-0}
ENV DAEMON=${DAEMON:-1}
ENV CONFIG=${CONFIG:-AUTO}
ENV GOLANG_VERSION="go1.19.2"
ENV ROCKSDB_VERSION=${ROCKSDB_VERSION:-v7.7.2}
ENV DAEMON_CONFIG=${DAEMON_CONFIG:-AUTO}
ENV GOPATH=$HOME/go
ENV PATH=$PATH:$GOPATH/bin
ENV CGO_CFLAGS="-I$HOME/rocksdb/include"
ENV CGO_LDFLAGS="-L$HOME/rocksdb -lrocksdb -lstdc++ -lm -lz -ldl -lbz2 -lsnappy -llz4 -lzstd"
# Install GOLANG
RUN echo "Installing GOLANG [$GOLANG_VERSION]..." && \
  cd /opt && wget https://dl.google.com/go/$GOLANG_VERSION.linux-amd64.tar.gz && \
  tar xf $GOLANG_VERSION.linux-amd64.tar.gz && \
  rm $GOLANG_VERSION.linux-amd64.tar.gz
RUN ln -s /opt/go/bin/go /usr/bin/go
RUN mkdir -p $GOPATH
RUN echo -n "GO version: " && go version
RUN echo -n "GOPATH: " && echo $GOPATH

# Install RocksDB
#RUN echo "Installing RocksDB [$ROCKSDB_VERSION]..." && \
#cd $HOME && git clone -b $ROCKSDB_VERSION --depth 1 https://github.com/facebook/rocksdb.git && \
#cd $HOME/rocksdb && CFLAGS=-fPIC CXXFLAGS='-fPIC -Wno-error=deprecated-copy -Wno-error=pessimizing-move -Wno-error=class-memaccess' PORTABLE=1 make -j 4 release

# Install BlockBook
#RUN echo "Installing BlockBook..." && \ 
#REPO_UNCAT=${BLOCKBOOKGIT_URL##*/} && \
#REPO=${REPO_UNCAT%%.*} && \
#GIT_USER=$(echo "$BLOCKBOOKGIT_URL" | grep -oP "(?<=github.com.)\w+(?=.$REPO)"); \
#VERSION=$(curl -ssL https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/environ.json | jq -r .version); \
#echo -e "REPO: $REPO, VERSION: $VERSION" && \
#cd $HOME && git clone $BLOCKBOOKGIT_URL && \
#cd $HOME/blockbook && \
#git checkout "$TAG" && \
#go mod download && \
#BUILDTIME=$(date --iso-8601=seconds); GITCOMMIT=$(git describe --always --dirty); \
#LDFLAGS="-X github.com/trezor/blockbook/common.version=${VERSION}-${TAG} -X github.com/trezor/blockbook/common.gitcommit=${GITCOMMIT} -X github.com/trezor/blockbook/common.buildtime=${BUILDTIME}" && \
#go build -tags rocksdb_6_16 -ldflags="-s -w ${LDFLAGS}"

COPY build.sh /build.sh
COPY daemon.sh /daemon.sh
COPY blockbook.sh /blockbook.sh
COPY check-health.sh /check-health.sh
COPY consensus.sh /consensus.sh
COPY utils.sh /utils.sh

RUN chmod 755 /blockbook.sh /daemon.sh /build.sh /check-health.sh /consensus.sh /utils.sh
RUN mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
VOLUME /root
EXPOSE $BLOCKBOOK_PORT 1337
HEALTHCHECK --start-period=10m --interval=4m --retries=5 --timeout=40s CMD ./check-health.sh
ENTRYPOINT ["/usr/bin/supervisord"]
