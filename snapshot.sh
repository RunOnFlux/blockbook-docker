#!/usr/bin/env bash
# Peer snapshots: instances of one Flux app seed each other.
#
# Flux moves instances between nodes all the time, and a new instance used to
# sync its daemon and index its chain from block 0 - days to weeks - so a large
# share of every blockbook app was always in initial sync. Now a synced
# instance keeps a snapshot of its chain data (create), snapshot_server.py
# serves it on container port 1337 to the other instances of the same app, and
# a new or far-behind instance downloads it before starting (restore).
#
# A snapshot costs almost no disk: database files that are never rewritten
# (LevelDB/RocksDB tables, blk/rev files) are hard links, only the small
# mutable files are copied, and the daemon and blockbook are stopped for the
# few seconds that takes so the copy is consistent.
#
#   snapshot.sh create              take a snapshot if this instance is synced
#   snapshot.sh restore             seed backend + index from the best peer
#   snapshot.sh restore-blockbook   seed only the index (backend is synced)
#   snapshot.sh reseed              reseed an instance that is far behind
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
SNAP=/root/snapshot
BACKEND=/root/$CONFIG_DIR/backend
BBDB=/root/blockbook-db
TMP=/root/restore.tmp
INTERVAL=${SNAPSHOT_INTERVAL:-86400}
MIN_FREE=${SNAPSHOT_MIN_FREE_PCT:-15}
API=https://api.runonflux.io

function log() { echo "| $(date '+%Y-%m-%d %H:%M:%S') $*"; }
function free_pct() { df -P /root | awk 'NR==2 { sub("%", "", $5); print 100 - $5 }'; }
function free_bytes() { df -P -B1 /root | awk 'NR==2 { print $4 }'; }
function bytes() { du -sb "$@" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }

# Hard links for files a database never rewrites, copies for the rest.
# $3=1 includes files at the top of $1 (blockbook-db); the backend's top level
# holds wallet.dat, configs and logs, which are never shared.
function link_tree() {
  local src=$1 dst=$2 top=$3
  mkdir -p "$dst"
  (cd "$src" && find . -mindepth 1 -type d ! -path './database' ! -path './database/*') | while read -r d; do
    mkdir -p "$dst/$d"
  done
  local depth=2
  [[ "$top" == "1" ]] && depth=1
  (cd "$src" && find . -mindepth $depth -type f ! -path './database/*' \
     ! -name 'wallet.dat' ! -name 'LOCK' ! -name '*.lock' ! -name '.lock' \
     ! -name 'LOG' ! -name 'LOG.old*' ! -name 'debug.log' ! -name '*.conf' ! -name '*.pid') | while read -r f; do
    case "${f##*/}" in
      *.ldb|*.sst|*.blob|blk*.dat|rev*.dat) ln "$src/$f" "$dst/$f" || return 1 ;;
      *) cp -p "$src/$f" "$dst/$f" || return 1 ;;
    esac
  done
}

# supervisorctl returns once the launcher has exited. Make sure the daemon has
# too: a copy taken while it still flushes has empty databases.
function daemon_stopped() {
  local name
  name=$(jq -r '.binary_name // empty' /root/daemon_config.json 2>/dev/null)
  [[ -n "$name" ]] || return 0
  for _ in $(seq 1 300); do
    pgrep -f "^([^ ]*/)?${name}( |$)" > /dev/null || return 0
    sleep 1
  done
  return 1
}

function bb_status() {
  curl -s -m 20 http://127.0.0.1:${BLOCKBOOK_PORT}/api/
}

function create() {
  [[ "$DAEMON" == "1" && -f /run/bb/bootstrapped ]] || return 0
  # A snapshot pins files the databases have since replaced, so it is the
  # first thing to give back when the disk fills up.
  if [[ -d $SNAP && $(free_pct) -lt $((MIN_FREE / 2)) ]]; then
    log "snapshot: only $(free_pct)% free, dropping the snapshot"
    rm -rf $SNAP
  fi
  if ls /run/bb/serving.* > /dev/null 2>&1; then
    return 0
  fi
  if [[ -f $SNAP/info.json ]]; then
    local created=$(jq -r .created $SNAP/info.json)
    local jitter=$(( $(cksum <<< "$FLUX_NODE_HOST_IP" | cut -d' ' -f1) % 7200 ))
    (( $(date +%s) - created < INTERVAL + jitter )) && return 0
  fi
  local status=$(bb_status)
  local insync=$(jq -r '.blockbook.inSync' <<< "$status" 2>/dev/null)
  local initial=$(jq -r '.blockbook.initialSync // false' <<< "$status" 2>/dev/null)
  local bbh=$(jq -r '.blockbook.bestHeight // 0' <<< "$status" 2>/dev/null)
  local beh=$(jq -r '.backend.blocks // 0' <<< "$status" 2>/dev/null)
  local hdr=$(jq -r '.backend.headers // .backend.blocks // 0' <<< "$status" 2>/dev/null)
  if [[ "$insync" != "true" || "$initial" == "true" ]] || (( bbh < 1 || beh < hdr - 2 || bbh < beh - 2 )); then
    return 0
  fi
  rm -rf $SNAP ${SNAP}.new
  if (( $(free_pct) < MIN_FREE )); then
    log "snapshot: only $(free_pct)% free, not keeping a snapshot"
    return 0
  fi
  log "snapshot: synced at $bbh, taking a snapshot"
  supervisorctl stop blockbook > /dev/null
  supervisorctl stop daemon > /dev/null
  local ok=1
  if ! daemon_stopped; then
    log "snapshot: the daemon did not stop"
    ok=0
  fi
  [[ "$ok" == "1" ]] && link_tree $BACKEND ${SNAP}.new/backend 0 && link_tree $BBDB ${SNAP}.new/blockbook-db 1 || ok=0
  supervisorctl start daemon > /dev/null
  supervisorctl start blockbook > /dev/null
  if [[ "$ok" != "1" ]]; then
    log "snapshot: copy failed, dropped"
    rm -rf ${SNAP}.new
    return 1
  fi
  jq -n --arg coin "$COIN" --arg app "$FLUX_APP_NAME" --arg image "$(cat /opt/blockbook/VERSION)" \
    --argjson created "$(date +%s)" --argjson height "$bbh" --argjson backend "$beh" \
    --argjson backend_bytes "$(bytes ${SNAP}.new/backend)" --argjson blockbook_bytes "$(bytes ${SNAP}.new/blockbook-db)" \
    '{coin: $coin, app: $app, image: $image, created: $created, height: $height, backend_height: $backend,
      backend_bytes: $backend_bytes, blockbook_bytes: $blockbook_bytes, bytes: ($backend_bytes + $blockbook_bytes)}' \
    > ${SNAP}.new/info.json
  mv ${SNAP}.new $SNAP
  log "snapshot: ready, $(jq -r .bytes $SNAP/info.json) bytes at height $bbh"
}

# Prints "ip:port bytes backend_bytes blockbook_bytes height" for each peer with
# a snapshot of this coin, best first; peers within 100 blocks of the best are
# shuffled so new instances do not all queue on the same one.
function peers() {
  local spec port endpoints
  if [[ -n "$SNAPSHOT_PEERS" ]]; then
    # "ip:port ip:port": seed from these instead of the app's other instances.
    endpoints=$SNAPSHOT_PEERS
  else
    spec=$(curl -sf -m 20 $API/apps/appspecifications/$FLUX_APP_NAME) || return 1
    port=${SNAPSHOT_PORT:-$(jq -r '(.data.compose // [.data]) | map(select(((.containerPorts // []) | map(tostring) | index("1337")) != null))
        | .[0] | .ports[((.containerPorts | map(tostring) | index("1337")))] // empty' <<< "$spec")}
    [[ -n "$port" ]] || { log "bootstrap: the app spec maps no port to 1337, no peer snapshots"; return 2; }
    endpoints=$(curl -sf -m 20 $API/apps/location/$FLUX_APP_NAME | jq -r '.data[].ip' | cut -d: -f1 | sort -u \
      | grep -vxF "$FLUX_NODE_HOST_IP" | sed "s/\$/:$port/")
  fi
  {
    for endpoint in $endpoints; do
      curl -sf -m 8 http://$endpoint/snapshot/info.json 2>/dev/null \
        | jq -r --arg p "$endpoint" --arg coin "$COIN" 'select(.coin == $coin) | "\($p) \(.bytes) \(.backend_bytes) \(.blockbook_bytes) \(.height)"' &
    done
    wait
  } | sort -k5 -n -r \
    | awk -v seed=$RANDOM 'BEGIN { srand(seed) } NR == 1 { best = $5 } { print ($5 >= best - 100 ? rand() : 1 + NR), $0 }' \
    | sort -n | cut -d' ' -f2-
}

# $1 = peer ip:port, $2 = path on the peer, $3 = members expected in the tar
function download() {
  local peer=$1 path=$2
  shift 2
  rm -rf $TMP && mkdir -p $TMP
  log "bootstrap: downloading http://$peer$path"
  curl -sf --connect-timeout 15 --speed-limit 51200 --speed-time 600 http://$peer$path | tar -x -C $TMP
  local rc=("${PIPESTATUS[@]}")
  if [[ "${rc[0]}" != "0" || "${rc[1]}" != "0" ]]; then
    log "bootstrap: download from $peer failed (curl ${rc[0]}, tar ${rc[1]})"
    return 1
  fi
  for m in "$@"; do
    [[ -e $TMP/$m ]] || { log "bootstrap: $peer sent no $m"; return 1; }
  done
}

# $1=1 restores only the index; $2=1 replaces local data even if it is close.
function restore() {
  local only_blockbook=$1 force=$2
  mkdir -p /run/bb $BACKEND $BBDB
  [[ "$only_blockbook" == "1" || "$force" == "1" ]] || trap 'touch /run/bb/bootstrapped' EXIT
  until [[ -f /run/bb/prepared ]]; do sleep 5; done
  if [[ "$PEER_BOOTSTRAP" != "1" || "$DAEMON" != "1" || ( -z "$FLUX_APP_NAME" && -z "$SNAPSHOT_PEERS" ) ]]; then
    return 0
  fi
  local candidates rc attempts=1
  local local_backend=$(bytes $BACKEND) local_bb=$(bytes $BBDB)
  # An empty instance waits a while for a peer to have a snapshot; one with a
  # chain only checks whether it is far behind, so a restart is not delayed.
  (( local_backend < 1000000000 )) && [[ "$only_blockbook" != "1" ]] && attempts=6
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    candidates=$(peers); rc=$?
    [[ -n "$candidates" || $rc == 2 ]] && break
    log "bootstrap: no peer snapshot found (attempt $attempt of $attempts)"
    (( attempt < attempts )) && sleep 300
  done
  [[ -n "$candidates" ]] || { log "bootstrap: no peer snapshot, syncing on our own"; return 0; }
  # Peers serve the download only to addresses that run the app, and a new
  # instance is listed a few minutes after it starts.
  if [[ -z "$SNAPSHOT_PEERS" && -n "$FLUX_NODE_HOST_IP" ]]; then
    for _ in $(seq 1 30); do
      curl -sf -m 20 $API/apps/location/$FLUX_APP_NAME | jq -e --arg ip "$FLUX_NODE_HOST_IP" \
        'any(.data[]; (.ip | split(":")[0]) == $ip)' > /dev/null && break
      sleep 30
    done
  fi

  local tried=0
  while read -r peer total backend_bytes bb_bytes height; do
    (( tried++ >= 3 )) && break
    if [[ "$only_blockbook" == "1" ]]; then
      (( $(free_bytes) > bb_bytes * 11 / 10 )) || { log "bootstrap: not enough disk for $bb_bytes bytes"; return 0; }
      download $peer /snapshot-blockbook.tar blockbook-db/CURRENT || continue
      rm -rf $BBDB && mv $TMP/blockbook-db $BBDB && rm -rf $TMP
      log "bootstrap: index restored from $peer at height $height"
      return 0
    fi
    # Keep what is here unless it is far behind the peer.
    if [[ "$force" != "1" ]] && (( local_backend * 2 >= backend_bytes && local_bb * 2 >= bb_bytes )); then
      log "bootstrap: local data ($local_backend + $local_bb bytes) is close to $peer's snapshot, keeping it"
      return 0
    fi
    if [[ "$force" != "1" ]] && (( local_backend * 10 >= backend_bytes * 9 )); then
      log "bootstrap: backend is synced but the index is far behind, taking only the index from $peer"
      (( $(free_bytes) + local_bb > bb_bytes * 11 / 10 )) || { log "bootstrap: not enough disk"; return 0; }
      rm -rf "${BBDB:?}"/*
      download $peer /snapshot-blockbook.tar blockbook-db/CURRENT || continue
      rm -rf $BBDB && mv $TMP/blockbook-db $BBDB && rm -rf $TMP
      log "bootstrap: index restored from $peer at height $height"
      return 0
    fi
    (( $(free_bytes) + local_backend + local_bb > total * 11 / 10 )) || { log "bootstrap: not enough disk for $total bytes"; return 0; }
    rm -rf "${BACKEND:?}"/* $BBDB/*
    local_backend=0 local_bb=0
    download $peer /snapshot.tar backend blockbook-db/CURRENT || continue
    # Only the chain data is replaced; configs, wallet and logs stay.
    cp -al $TMP/backend/. $BACKEND/ && rm -rf $BBDB && mv $TMP/blockbook-db $BBDB && rm -rf $TMP
    echo -e "Bootstrap [LOCKED] from peer $peer" > /root/BOOTSTRAP_LOCKED
    log "bootstrap: restored from $peer at height $height"
    return 0
  done <<< "$candidates"
  rm -rf $TMP
  log "bootstrap: every peer download failed, syncing on our own"
}

# Hourly. An instance indexed below 90% of the best peer's snapshot (it came
# up while no peer had a snapshot yet, or was stuck) takes the snapshot rather
# than catching up block by block.
function reseed() {
  [[ "$PEER_BOOTSTRAP" == "1" && "$DAEMON" == "1" && -f /run/bb/bootstrapped && -n "$FLUX_APP_NAME" ]] || return 0
  ls /run/bb/serving.* > /dev/null 2>&1 && return 0
  local status indexed best height
  status=$(bb_status)
  [[ -n "$status" ]] || return 0
  indexed=$(jq -r '.blockbook.bestHeight // 0' <<< "$status" 2>/dev/null)
  best=$(peers | head -n 1)
  [[ -n "$best" ]] || return 0
  height=$(awk '{ print $5 }' <<< "$best")
  (( ${indexed:-0} * 10 < height * 9 )) || return 0
  log "reseed: indexed ${indexed:-0}, a peer has a snapshot at $height, reseeding"
  supervisorctl stop blockbook daemon > /dev/null
  daemon_stopped || { log "reseed: the daemon did not stop"; supervisorctl start daemon blockbook > /dev/null; return 1; }
  restore 0 1
  supervisorctl start daemon blockbook > /dev/null
}

case "$1" in
  create) create ;;
  restore) restore 0 0 ;;
  restore-blockbook) restore 1 0 ;;
  reseed) reseed ;;
  *) echo "usage: $0 create|restore|restore-blockbook|reseed"; exit 1 ;;
esac
