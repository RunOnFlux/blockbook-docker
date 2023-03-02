#!/usr/bin/env bash
RPC_HOST="${RPC_HOST:-localhost}"
RPC_URL_PROTOCOL="${RPC_URL_PROTOCOL:-http}"
CFG_FILE=/root/blockchaincfg.json
echo -e "| BLOCKBOOK LUNCHER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
echo -e "---------------------------------------------------------------------------"
if [[ "$DAEMON_CONFIG" != "AUTO" ]]; then
  echo -e "| Blockbook Settings: COIN=$COIN, RPC_USER=$RPC_USER, RPC_PASS=$RPC_PASS, RPC_PORT=$RPC_PORT, BLOCKBOOK_PORT=$BLOCKBOOK_PORT, RPC_HOST=$RPC_HOST, RPC_URL_PROTOCOL=$RPC_URL_PROTOCOL"
else
  echo -e "| Blockbook Settings: COIN=$COIN, BLOCKBOOK_PORT=$BLOCKBOOK_PORT, DAEMON_CONFIG=AUTO"
fi
echo -e "| Awaiting for Blockbook build..."
while true; do
   if [[ -f $CFG_FILE && -f $HOME/blockbook/blockbook ]]; then
     sleep 20
     break
   fi
   sleep 20
done
if [[ "$BOOTSTRAP" == "1" && ! -f /root/BOOTSTRAP_LOCKED ]]; then
  echo -e "| Awaiting for bootstraping..."
  while true; do
   if [[ -f /root/BOOTSTRAP_LOCKED  ]]; then
     sleep 20
     break
   fi
   sleep 180
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
exec ./blockbook -sync -blockchaincfg=$CFG_FILE -datadir=/root/blockbook-db -debug -workers=${WORKERS:-1} -dbcache=${DBCACHE:-500} -public=:${BLOCKBOOK_PORT} -logtostderr
echo -e "---------------------------------------------------------------------------"
