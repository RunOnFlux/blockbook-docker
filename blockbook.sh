#!/usr/bin/env bash
RPC_HOST="${RPC_HOST:-localhost}"
RPC_URL_PROTOCOL="${RPC_URL_PROTOCOL:-http}"
CFG_FILE=/root/blockchaincfg.json

function getArgs(){
  argsArray=($(echo "$1" | grep -oP -- '-\w+' | sort -u))
}

function trim() {
  local var="$*"
  # remove leading whitespace characters
  var="${var#"${var%%[![:space:]]*}"}"
  # remove trailing whitespace characters
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

echo -e "| BLOCKBOOK LAUNCHER v3 [$(date '+%Y-%m-%d %H:%M:%S')] $(cat /opt/blockbook/VERSION)"
echo -e "---------------------------------------------------------------------------"
if [[ "$DAEMON_CONFIG" != "AUTO" ]]; then
  echo -e "| Blockbook Settings: COIN=$COIN, RPC_USER=$RPC_USER, RPC_PORT=$RPC_PORT, BLOCKBOOK_PORT=$BLOCKBOOK_PORT, RPC_HOST=$RPC_HOST, RPC_URL_PROTOCOL=$RPC_URL_PROTOCOL"
else
  echo -e "| Blockbook Settings: COIN=$COIN, BLOCKBOOK_PORT=$BLOCKBOOK_PORT, DAEMON_CONFIG=AUTO"
fi
until [[ -f /run/bb/prepared && -f /run/bb/bootstrapped && -f $CFG_FILE ]]; do
  sleep 10
done
if [[ "$BOOTSTRAP" == "1" && "$DAEMON" == "1" ]]; then
  echo -e "| Awaiting the daemon's bootstrap step..."
  until [[ -f /run/bb/daemon_bootstrap_done ]]; do
    sleep 20
  done
fi
if [[ ! -f /root/CONFIG_CRETED ]]; then
  if [[ "$DAEMON_CONFIG" != "AUTO" ]]; then
    echo -e "| Updating blockchaincfg.json..."
    echo "$(jq -r --arg key "rpc_user" --arg value "$RPC_USER" '.[$key]=$value' $CFG_FILE)" > $CFG_FILE
    echo "$(jq -r --arg key "rpc_pass" --arg value "$RPC_PASS" '.[$key]=$value' $CFG_FILE)" > $CFG_FILE
    echo "$(jq -r --arg key "rpc_timeout" --argjson value 50 '.[$key]=$value' $CFG_FILE)" > $CFG_FILE
    echo "$(jq -r --arg key "rpc_url" --arg value "$RPC_URL_PROTOCOL://$RPC_HOST:$RPC_PORT" '.[$key]=$value' $CFG_FILE)" > $CFG_FILE
  fi
  echo "Disabled updating blockchaincfg.json..." > /root/CONFIG_CRETED
else
  echo -e "| Blockchaincfg.json [LOCKED]..."
fi
cd /opt/blockbook
echo -e "| Starting Blockbook ($COIN)..."
if [[ ! -d /root/blockbook-db ]]; then
  mkdir -p /root/blockbook-db
fi

# -dbcache is in bytes: the old default of 500 gave RocksDB a 500 byte cache.
exec_string="$HOME/blockbook/blockbook -sync -blockchaincfg=$CFG_FILE -datadir=/root/blockbook-db -workers=${WORKERS:-4} -dbcache=${DBCACHE:-536870912} -public=:${BLOCKBOOK_PORT} -logtostderr"
args_to_remove=( -datadir -debug -log -blockchaincfg -sync -logtostderr -public )
additional_params_from_blockbook=$(jq -r .blockbook.additional_params $HOME/blockbook/configs/coins/${COIN}.json)
additional_params_from_docker="${BLOCKBOOK_PARAMS}"

if [[ "$additional_params_from_blockbook" != "" &&  "$additional_params_from_blockbook" != "null" ]]; then
  blockbook_clean="${additional_params_from_blockbook}"
  for arg in "${args_to_remove[@]}"; do
      blockbook_clean=$(echo "${blockbook_clean}" | sed "s/\($arg[= ][^ ]*\)//g")
  done
  blockbook_clean=$(trim "${blockbook_clean}")
fi

if [[ "$additional_params_from_docker" != "" && "$additional_params_from_docker" != "null" ]]; then
  docker_clean="${additional_params_from_docker}"
  for arg in "${args_to_remove[@]}"; do
      docker_clean=$(echo "${docker_clean}" | sed "s/\($arg[= ][^ ]*\)//g")
  done
  docker_clean=$(trim "${docker_clean}")
  getArgs "${docker_clean}"
fi

if [[ "$argsArray" != "" ]]; then
  final_clean="${blockbook_clean}"
  for arg in "${argsArray[@]}"; do
      final_clean=$(echo "${final_clean}" | sed "s/\($arg[= ][^ ]*\)//g")
  done
  final_clean=$(trim "${final_clean}")
else
  final_clean="${blockbook_clean}"
fi

clean_variable=$(trim "${docker_clean} ${final_clean}")
# A pruned backend has no txindex: blockbook gets a confirmed transaction from
# its block and downloads a pruned block again from a peer (patches/0001). What
# it fetched stays in the tx cache, emptied past TXCACHE_MAX_GB. The extended
# index (every input's previous txid and every spent output's spender, ~245 GB
# of Bitcoin's index in 2026) does not fit next to the rest of the index in an
# 820 GB app.
if [[ "$PRUNE_BACKEND" == "1" ]]; then
  kept=""
  for arg in ${clean_variable}; do
    [[ "$arg" =~ ^--?(extendedindex|notxcache)(=|$) ]] || kept="${kept} ${arg}"
  done
  clean_variable=$(trim "${kept} -prunedbackend -txcachemaxgb=${TXCACHE_MAX_GB:-20}")
fi
if [[ "$clean_variable" != "" ]]; then
   getArgs "${clean_variable}"
   for arg in "${argsArray[@]}"; do
     exec_string=$(echo "${exec_string}" | sed "s/\($arg[= ][^ ]*\)//g")
   done
   exec_string=$(trim "${exec_string}")
fi

exec ${exec_string} ${clean_variable}
echo -e "---------------------------------------------------------------------------"
