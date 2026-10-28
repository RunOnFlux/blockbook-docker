#!/usr/bin/env bash
# Wipes a database only when its own process reports it unusable.
#
# The previous version also wiped the whole backend on "invalid header
# received" and "InvalidChainFound", which every node logs whenever a peer is
# on another fork. That kept instances re-syncing from block 0 forever, and
# left blockbook's index ahead of a backend that had just been emptied.
CONFIG_DIR=${CONFIG_DIR:-$COIN}
CF_LOGS=/root/corrupion_events.log
# The "does not match" errors: an index built for another coin or with other
# settings (a testnet3 index after the switch to testnet4, a full node's index
# under PRUNE_BACKEND or the other way round), which blockbook refuses to open.
BLOCKBOOK_PATTERNS='rocksDB: Corruption|SST file is ahead of WALs|Coins do not match|ExtendedIndex setting does not match|PrunedBackend setting does not match|does not match the required version|BlockGolombFilterP does not match|BlockFilterScripts does not match|BlockFilterUseZeroedKey does not match'
# An index that can only be rebuilt: a first (bulk) sync that was killed, most
# often out of memory, leaves it marked inconsistent, and an index ahead of a
# chain it has no undo data for cannot disconnect its blocks.
INDEX_PATTERNS='database is in inconsistent state|Cannot disconnect blocks'
BACKEND_PATTERNS='Corrupted block database detected|Error opening block database|Fatal LevelDB error|Error initializing block database|database corrupted'

[[ -f /run/bb/prepared && -f /run/bb/bootstrapped ]] || exit 0
echo -e "------------------------------------------ [$(date '+%Y-%m-%d %H:%M:%S')] corruption check"

if [[ -f /root/blockbook.log ]] && tail -n 5000 /root/blockbook.log | grep -aqE "$BLOCKBOOK_PATTERNS|$INDEX_PATTERNS"; then
  echo "[$(date "+%d/%m/%y %H:%M:%S %Z %z")] - BlockBook Corruption detected" >> $CF_LOGS
  echo -e "| RocksDB corruption, cleaning the blockbook database"
  if tail -n 5000 /root/blockbook.log | grep -aq "database is in inconsistent state"; then
    # It would be killed at the same point again: blockbook.sh syncs with one
    # worker from now on, block by block, consistent after every block.
    echo -e "| The first sync was interrupted, rebuilding with one worker"
    touch /root/blockbook-db.sequential
  fi
  supervisorctl stop blockbook > /dev/null 2>&1
  rm -rf /root/blockbook-db/*
  : > /root/blockbook.log
  # A synced peer's index is far quicker than indexing from block 0.
  /snapshot.sh restore-blockbook
  # A pruned backend no longer has the old blocks, so an index no peer could
  # provide can only be rebuilt together with the backend.
  if [[ "$PRUNE_BACKEND" == "1" && "$DAEMON" == "1" && ! -f /root/blockbook-db/CURRENT ]]; then
    echo -e "| No peer index and the backend is pruned, starting the backend over too"
    supervisorctl stop daemon > /dev/null 2>&1
    rm -rf "/root/${CONFIG_DIR:?}"/backend/* /root/BOOTSTRAP_LOCKED
    /snapshot.sh restore
    supervisorctl start daemon > /dev/null 2>&1
  fi
  supervisorctl start blockbook > /dev/null 2>&1
fi

DEBUG_LOG=/root/$CONFIG_DIR/backend/debug.log
if [[ "$DAEMON" == "1" && -f $DEBUG_LOG ]] && tail -n 5000 $DEBUG_LOG | grep -aqE "$BACKEND_PATTERNS"; then
  echo "[$(date "+%d/%m/%y %H:%M:%S %Z %z")] - Backend Corruption detected" >> $CF_LOGS
  echo -e "| Backend database corruption, starting over from a peer snapshot or block 0"
  supervisorctl stop blockbook daemon > /dev/null 2>&1
  # The index cannot be kept: it would be ahead of the emptied backend.
  rm -rf "/root/${CONFIG_DIR:?}"/backend/* /root/blockbook-db/* /root/BOOTSTRAP_LOCKED
  /snapshot.sh restore
  supervisorctl start daemon blockbook > /dev/null 2>&1
fi
echo -e "| corruption check done"
