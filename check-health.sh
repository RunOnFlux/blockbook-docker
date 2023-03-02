#!/usr/bin/env bash
 CONFIG_FILE=${CONFIG_FILE:-$COIN}
 CONFIG_DIR=${CONFIG_DIR:-$COIN}
### BlockBook checking
 blockbookapi=$(curl -sSL  http://localhost:$BLOCKBOOK_PORT/api 2>/dev/null | jq .)
 bloks=$(jq -r .backend.blocks <<< "$blockbookapi")
 headers=$(jq -r .backend.headers <<< "$blockbookapi")
 blockbook=$(jq -r .blockbook.bestHeight <<< "$blockbookapi")
 if [[ $bloks != "" && $blockbook != "" ]]; then  
   DAEMON_SIZE=$(du -sb /root/$CONFIG_DIR | awk '{printf("%0.2f GB\n", $1/1000/1000/1000)}')
   BLOCKBOOK_SIZE=$(du -sb /root/blockbook-db | awk '{printf("%0.2f GB\n", $1/1000/1000/1000)}')
   if [[ $headers != "" && $headers != "null" ]]; then
     progress1=$(awk 'BEGIN {total=ARGV[1] / ARGV[2]; printf("%.2f", total*100)}' $bloks $headers)
     progress2=$(awk 'BEGIN {total=ARGV[1] / ARGV[2]; printf("%.2f", total*100)}' $blockbook $headers)
     msg="Blockbook = [OK], Daemon = [OK], Daemon Sync: ${progress1}%, Blockbook Sync: ${progress2}%, Backend Size: $DAEMON_SIZE, Blockbook Size: $BLOCKBOOK_SIZE"
   else
     msg="Blockbook = [OK], Daemon = [OK], Daemon Height: ${bloks}, Blockbook Height: ${blockbook}, Backend Size: $DAEMON_SIZE, Blockbook Size: $BLOCKBOOK_SIZE"
   fi
   echo -e "${msg}"
   exit
 else
   msg="Blockbook = [FAILED]"
 fi
 if [[ "$CLI_NAME" == "" ]]; then
   if [[ -f /root/daemon_config.json ]]; then
     CLI_NAME=$(jq -r .cli_name /root/daemon_config.json)
   fi
 fi
 if [[ "$CLI_NAME" == "" ]]; then
   msg="$msg, Daemon = [HEALCHECK DISABLED]"
   echo -e "$msg"
   exit 1
 fi
## Checking Daemon
 if [[ -f /root/${CONFIG_DIR}/${CONFIG_FILE}.conf ]]; then
   CURRENT_NODE_HEIGHT=$(${CLI_NAME} -conf="/root/${CONFIG_DIR}/${CONFIG_FILE}.conf" -getinfo 2>/dev/null | jq .blocks)
   if [[ "$CURRENT_NODE_HEIGHT" == "" ]]; then
     CURRENT_NODE_HEIGHT=$(${CLI_NAME} -conf="/root/${CONFIG_DIR}/${CONFIG_FILE}.conf" getinfo 2>/dev/null | jq .blocks)
   fi
 else
   CURRENT_NODE_HEIGHT=$(${CLI_NAME} -rpcpassword="$RPC_PASS" -rpcuser="$RPC_USER" -getinfo 2>/dev/null | jq .blocks)
   if [[ "$CURRENT_NODE_HEIGHT" == "" ]]; then
     CURRENT_NODE_HEIGHT=$(${CLI_NAME} -rpcpassword="$RPC_PASS" -rpcuser="$RPC_USER" getinfo 2>/dev/null | jq .blocks)
   fi
 fi

 if ! egrep -o "^[0-9]+$" <<< "$CURRENT_NODE_HEIGHT" &>/dev/null; then
  msg="$msg, Daemon = [FAILED]"
  echo -e "$msg"
  exit 1
 else
   msg="$msg, Daemon = [OK]"
   echo -e "$msg"
   exit 1
 fi
