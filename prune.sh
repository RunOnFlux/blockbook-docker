#!/usr/bin/env bash
# Keeps a pruned backend just ahead of blockbook (PRUNE_BACKEND=1).
#
# A Bitcoin node that keeps every block no longer fits in a Flux app: 886 GB
# of blocks in October 2026 against an app limit of 820 GB, before txindex.
# Blockbook only needs a block until it has indexed it, so the daemon runs
# with prune=1 (manual pruning) and this job prunes what blockbook has
# indexed, minus a reorg margin. While blockbook indexes slower than the
# daemon downloads, the daemon is taken off the network so blocks waiting to
# be indexed cannot fill the disk. Blockbook gets old transactions from their
# blocks, downloading pruned ones again from peers (patches/0001).
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
KEEP=${PRUNE_KEEP_BLOCKS:-2000}
MAX_GB=${PRUNE_MAX_BLOCKS_GB:-80}
LOG=/root/prune_events.log

[[ "$PRUNE_BACKEND" == "1" && "$DAEMON" == "1" && -f /run/bb/bootstrapped ]] || exit 0
CLI_NAME=${CLI_NAME:-$(jq -r '.cli_name // empty' /root/daemon_config.json 2>/dev/null)}
[[ -n "$CLI_NAME" ]] && command -v "$CLI_NAME" > /dev/null || exit 0

function cli() {
  timeout 300 "$CLI_NAME" -conf="/root/$CONFIG_DIR/$CONFIG_FILE.conf" \
    -rpcuser="$(jq -r .rpc_user /root/blockchaincfg.json)" -rpcpassword="$(jq -r .rpc_pass /root/blockchaincfg.json)" "$@"
}

INDEXED=$(curl -s -m 20 http://127.0.0.1:${BLOCKBOOK_PORT}/api | jq -r '.blockbook.bestHeight // 0' 2>/dev/null)
INDEXED=${INDEXED:-0}
if (( INDEXED > KEEP + 288 )); then
  cli pruneblockchain $((INDEXED - KEEP)) > /dev/null 2>&1
fi

BLOCKS_GB=$(du -s --block-size=1G /root/$CONFIG_DIR/backend/blocks 2>/dev/null | cut -f1)
BLOCKS_GB=${BLOCKS_GB:-0}
ACTIVE=$(cli getnetworkinfo 2>/dev/null | jq -r '.networkactive')
if (( BLOCKS_GB > MAX_GB )) && [[ "$ACTIVE" == "true" ]]; then
  cli setnetworkactive false > /dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLOCKS_GB} GB of blocks waiting for blockbook (indexed $INDEXED), network paused" >> $LOG
elif (( BLOCKS_GB < MAX_GB * 3 / 4 )) && [[ "$ACTIVE" == "false" ]]; then
  cli setnetworkactive true > /dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] blocks down to ${BLOCKS_GB} GB (indexed $INDEXED), network resumed" >> $LOG
fi
