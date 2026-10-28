#!/usr/bin/env bash
# End-to-end test of an image on a private regtest chain:
#   1. instance A starts bitcoind + blockbook, mines 150 blocks, indexes them
#   2. A takes a peer snapshot and serves it on port 1337
#   3. instance B, with an empty volume, seeds from A and starts at height 150
#   4. A's chain is marked invalid, heal.sh brings it back
#   5. instance P runs a pruned backend and gets pruned blocks again from A
# plus start-up checks for the daemons that broke in production.
#
#   test/smoke.sh <image>
set -euo pipefail
IMAGE=$1
NET=bbtest
COIN=bitcoin_regtest
CONF=/root/$COIN/$COIN.conf

cleanup() {
  for c in bb-a bb-b bb-p bb-bcash bb-flux; do
    echo "::group::logs $c"
    docker exec $c bash -c 'supervisorctl status; ps -eo pid,etime,args | cut -c1-200; tail -n 80 /root/*.log' 2>/dev/null || true
    echo "::endgroup::"
  done
  docker rm -f bb-a bb-b bb-p bb-bcash bb-flux > /dev/null 2>&1 || true
  docker network rm $NET > /dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() { # seconds description command...
  local t=$1 what=$2 out=; shift 2
  for _ in $(seq 1 "$t"); do
    if out=$("$@" 2>&1); then echo "ok: $what"; return 0; fi
    sleep 1
  done
  echo "FAILED: $what"; echo "last attempt: ${out:0:1000}"; return 1
}
# set -e ignores a failing "! cmd", so negative checks go through this.
refute() { if "$@" > /dev/null 2>&1; then echo "FAILED: expected to fail: $*"; exit 1; fi; }
api() { docker exec "$1" curl -sSf -m 20 http://127.0.0.1:19121/api/; }
height_is() {
  local s; s=$(api "$1") || return 1
  [[ "$(jq -r .blockbook.bestHeight <<< "$s")" == "$2" ]] || { jq -c '{blockbook: .blockbook | {bestHeight, inSync, initialSync}, backend: .backend | {blocks, error}}' <<< "$s"; return 1; }
}
cli() { local c=$1; shift; docker exec "$c" bitcoin-cli -conf=$CONF -rpcuser=rpc -rpcpassword=rpc "$@"; }

docker network create $NET > /dev/null
run() { # name extra-args...
  local name=$1; shift
  docker run -d --name "$name" --network $NET -e COIN=$COIN -e BLOCKBOOK_PORT=19121 "$@" "$IMAGE" > /dev/null
}

run bb-a -e SNAPSHOT_PUBLIC=1 -e PEER_BOOTSTRAP=0 -e HEAL_MIN_LEAD=5 -e EXTRACONFIG=listen=1
wait_for 300 "A: bitcoind answers" cli bb-a getblockcount
cli bb-a generatetodescriptor 150 'raw(51)' > /dev/null
wait_for 300 "A: blockbook indexed 150 blocks" height_is bb-a 150
[[ "$(api bb-a | jq -r .blockbook.inSync)" == "true" ]]
docker exec bb-a cat /opt/blockbook/VERSION
# cron loads its file only if its mtime is later than the second cron read it
docker exec bb-a bash -c '(( $(stat -c %Y /etc/cron.d/blockbook) > $(date -d "$(ps -o lstart= -p $(pgrep -x cron))" +%s) ))' \
  || { echo "FAILED: the cron file was not touched after cron started"; exit 1; }
# the explorer pages render with the fork's UI and its stylesheet is served
HOME_PAGE=$(docker exec bb-a curl -sSf -m 20 http://127.0.0.1:19121/)
HUB_CSS=$(grep -o '/static/css/hub[^"]*\.css' <<< "$HOME_PAGE" | head -1)
[[ -n "$HUB_CSS" ]] || { echo "FAILED: the explorer home page has no hub stylesheet"; exit 1; }
docker exec bb-a curl -sSf -m 20 -o /dev/null "http://127.0.0.1:19121$HUB_CSS"
docker exec bb-a curl -sSf -m 20 -o /dev/null "http://127.0.0.1:19121/block/1"

docker exec bb-a bash -c '. /run/bb/env.sh; /snapshot.sh create'
docker exec bb-a cat /root/snapshot/info.json | jq -e '.height == 150 and .bytes > 0'
wait_for 120 "A: blockbook back after the snapshot" height_is bb-a 150
# blockbook used to abort now and then when stopped (patches/0002)
refute docker exec bb-a grep -q "possibly previous ungraceful shutdown" /root/blockbook.log
docker exec bb-a test ! -e /root/snapshot/backend/wallet.dat
docker exec bb-a bash -c "test -z \"\$(find /root/snapshot -name '*.conf')\""

A_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" bb-a)
run bb-b --memory=4g -e PEER_BOOTSTRAP=1 -e SNAPSHOT_PEERS="$A_IP:1337"
wait_for 300 "B: seeded from A and serving height 150" height_is bb-b 150
docker exec bb-b grep -q "restored from $A_IP" /root/bootstrap.log
[[ "$(cli bb-b getblockcount)" == "150" ]]
# A first sync killed out of memory leaves the index marked inconsistent, and
# blockbook refuses to open it. corruption.sh rebuilds it (from A's snapshot
# here) and blockbook continues with one worker.
docker exec bb-b bash -c 'echo "E1028 blockbook.go:292] internalState: database is in inconsistent state and cannot be used" >> /root/blockbook.log; . /run/bb/env.sh; /corruption.sh'
docker exec bb-b test -f /root/blockbook-db.sequential
wait_for 300 "B: index rebuilt after an interrupted first sync" height_is bb-b 150
B_PID=$(docker exec bb-b pgrep -x blockbook)
B_ARGS=$(docker exec bb-b bash -c "tr '\0' ' ' < /proc/$B_PID/cmdline")
[[ "$B_ARGS" == *-workers=1* ]] || { echo "FAILED: B blockbook args: $B_ARGS"; exit 1; }
docker exec bb-b bash -c "tr '\0' '\n' < /proc/$B_PID/environ | grep -q '^GOMEMLIMIT=[0-9]*MiB$'"

# supervisorctl stop returns only once the daemon has exited: bitcoind renames
# itself b-shutoff while it flushes, and a wait on its name returned too early.
docker exec bb-a bash -c 'supervisorctl stop daemon > /dev/null; ! pgrep -f "^([^ ]*/)?bitcoind( |$)"'
docker exec bb-a supervisorctl start daemon > /dev/null
wait_for 120 "A: bitcoind back after a stop" cli bb-a getblockcount

TIP=$(cli bb-a getblockhash 140)
cli bb-a invalidateblock "$TIP"
[[ "$(cli bb-a getblockcount)" == "139" ]]
docker exec bb-a bash -c '. /run/bb/env.sh; /heal.sh'
wait_for 60 "A: heal.sh reconsidered the invalid chain" bash -c "[[ \$(docker exec bb-a bitcoin-cli -conf=$CONF -rpcuser=rpc -rpcpassword=rpc getblockcount) == 150 ]]"

# Pruned backend: no txindex and manual pruning. Blockbook gets a confirmed
# transaction from its block and downloads a pruned block again from a peer
# (A keeps every block), or with no peer answers from its index (patches/0001).
# fastprune makes regtest block files small enough to be pruned.
# -extendedindex stands in for bitcoin.json's, which PRUNE_BACKEND must drop.
run bb-p -e PEER_BOOTSTRAP=0 -e PRUNE_BACKEND=1 -e PRUNE_KEEP_BLOCKS=10 -e BLOCKBOOK_PARAMS=-extendedindex \
  -e EXTRACONFIG="fastprune=1\naddnode=$A_IP:18444"
wait_for 300 "P: bitcoind answers" cli bb-p getblockcount
docker exec bb-p grep -q '^prune=1' $CONF
refute docker exec bb-p grep -q '^txindex' $CONF
wait_for 120 "P: blockbook running" docker exec bb-p pgrep -x blockbook
P_ARGS=$(docker exec bb-p bash -c 'tr "\0" " " < /proc/$(pgrep -x blockbook)/cmdline')
[[ "$P_ARGS" == *-prunedbackend* && "$P_ARGS" == *-txcachemaxgb=20* && "$P_ARGS" != *-extendedindex* && "$P_ARGS" != *-notxcache* ]] || { echo "FAILED: pruned blockbook args: $P_ARGS"; exit 1; }
wait_for 300 "P: synced A's 150 blocks" bash -c "[[ \$(docker exec bb-p bitcoin-cli -conf=$CONF -rpcuser=rpc -rpcpassword=rpc getblockcount) == 150 ]]"
# Two coinbases to an address, then enough blocks for the first files to be pruned
ADDR=$(cli bb-p deriveaddresses "$(cli bb-p getdescriptorinfo 'wpkh(0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798)' | jq -r .descriptor)" | jq -r '.[0]')
cli bb-p generatetoaddress 2 "$ADDR" > /dev/null
cli bb-p generatetodescriptor 850 'raw(51)' > /dev/null
wait_for 300 "P: blockbook indexed 1002 blocks" height_is bb-p 1002
TX5=$(cli bb-p getblock "$(cli bb-p getblockhash 5)" | jq -r '.tx[0]')
TX6=$(cli bb-p getblock "$(cli bb-p getblockhash 6)" | jq -r '.tx[0]')
docker exec bb-p bash -c '. /run/bb/env.sh; /prune.sh'
cli bb-p getblockchaininfo | jq -e '.pruned == true and .pruneheight > 152'
refute cli bb-p getblock "$(cli bb-p getblockhash 151)"
refute cli bb-p getrawtransaction "$TX5"
P_API=http://127.0.0.1:19121/api/v2
# A history page of pruned blocks, a transaction, its backend JSON and a block
# all come back complete, the blocks downloaded from A again.
docker exec bb-p curl -sf "$P_API/address/$ADDR?details=txs" | jq -e '.txs == 2 and ([.transactions[] | select(.hex != null and .vsize > 0 and .vin[0].coinbase != null)] | length) == 2'
cli bb-p getblock "$(cli bb-p getblockhash 151)" > /dev/null
docker exec bb-p curl -sf "$P_API/tx/$TX5" | jq -e '.blockHeight == 5 and .hex != null and .vsize > 0'
docker exec bb-p curl -sf "$P_API/tx-specific/$TX5" | jq -e '.vsize > 0 and .blockhash != null'
docker exec bb-p curl -sf "$P_API/block/7" | jq -e '.height == 7 and .txCount == 1'
# With no peer an old transaction comes from the index, fee rate included.
cli bb-p addnode "$A_IP:18444" remove
cli bb-p disconnectnode "$A_IP:18444"
wait_for 60 "P: no peers" bash -c "[[ \$(docker exec bb-p bitcoin-cli -conf=$CONF -rpcuser=rpc -rpcpassword=rpc getconnectioncount) == 0 ]]"
docker exec bb-p curl -sf "$P_API/tx/$TX6" | jq -e '.blockHeight == 6 and .vsize > 0 and .hex == null'
# An index blockbook refuses to open is wiped. With no peer snapshot to restore
# it from and the old blocks pruned, the backend starts over too, and both get
# the chain from A again (the addnode is in the config).
P_OUT=$(docker exec bb-p bash -c 'echo "Coins do not match. DB coin Testnet, RPC coin Testnet4" >> /root/blockbook.log; . /run/bb/env.sh; /corruption.sh')
echo "$P_OUT"
[[ "$P_OUT" == *"starting the backend over too"* ]] || { echo "FAILED: the pruned backend was not started over"; exit 1; }
wait_for 600 "P: backend and index rebuilt from A" height_is bb-p 1002

# Bitcoin Cash Node 29 needs glibc 2.34; on the old Debian 11 image it exited at once.
docker run -d --name bb-bcash --network $NET -e COIN=bcash -e BLOCKBOOK_PORT=9131 -e PEER_BOOTSTRAP=0 "$IMAGE" > /dev/null
wait_for 600 "bcash: bitcoind running" docker exec bb-bcash pgrep -x bitcoind
sleep 30
docker exec bb-bcash pgrep -x bitcoind > /dev/null
refute docker exec bb-bcash grep -q GLIBC /root/backend.log
docker exec bb-bcash jq -r .daemon_url /root/daemon_config.json | grep -q 29.2.0

# Flux gets fluxd from overrides.json, not the version upstream pins.
docker run -d --name bb-flux --network $NET -e COIN=flux -e BLOCKBOOK_PORT=9158 -e PEER_BOOTSTRAP=0 "$IMAGE" > /dev/null
wait_for 600 "flux: fluxd installed" docker exec bb-flux test -x /usr/local/bin/fluxd
docker exec bb-flux jq -r .daemon_url /root/daemon_config.json | grep -q v9.1.0

docker run --rm --entrypoint zebrad "$IMAGE" --version
echo "smoke test passed"
