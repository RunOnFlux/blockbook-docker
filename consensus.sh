#!/usr/bin/env bash
function parse_template(){
 if [[ $(jq -r .$2 /root/$3.json 2>/dev/null) != "null" ]]; then
  return
 fi
 echo -e "| Parsing exec command template..."
 TEMPLATE=$(jq -r .backend.exec_command_template <<< "$1")
 BIN_PATH=($TEMPLATE)
 DATA_PATH=${BIN_PATH[1]}
 CONF_PATH=${BIN_PATH[2]}
 if [[ $(grep "\-pid" <<< $TEMPLATE) ]]; then
   TEMPLATE="$BIN_PATH $DATA_PATH $CONF_PATH"
   TEMPLATE=$(sed "s/${BIN_PATH//\//\\/}/$BINARY_NAME/g" <<< $TEMPLATE)
 else
   TEMPLATE=$(sed "s|/bin/sh -c '{{.Env.BackendInstallPath}}/{{.Coin.Alias}}/|""|" <<< $TEMPLATE)
 fi
 KEY_LIST=($(grep -oP "{{.*?}}" <<< $TEMPLATE))
 LENGTH=${#KEY_LIST[@]}
 for (( j=0; j<${LENGTH}; j++ ));
 do
   re="^\{\{(.*)\}\}$"
   if [[ "${KEY_LIST[$j]}" =~ $re ]]; then
     POSITION=${BASH_REMATCH[1]}
     NEW_ENTRY=$(jq -r "${POSITION,,}" /root/$4.json)
     TEMPLATE=$(sed "s|${KEY_LIST[$j]}|"$NEW_ENTRY"|" <<< $TEMPLATE)
   fi
 done
 TEMPLATE=$(sed "s/'/""/g" <<< $TEMPLATE)
 TEMPLATE=$(sed "s/\"/\'/g" <<< $TEMPLATE)
 if [[ ! -f /root/$3.json ]]; then
   echo "{}" > /root/$3.json
 fi
 echo "$(jq -r --arg key "$2" --arg value "$TEMPLATE" '.[$key]=$value' /root/$3.json)" > /root/$3.json
 echo -e "| RUN CMD: $(jq -r .$2 /root/$3.json)"
}

function create_consensus_config(){
  if [[ ! -f /root/consensus.json ]]; then
    echo "{}" > /root/consensus.json
    echo "$(jq -r --arg value "${COIN}_consensus" '.coin.alias=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "/root" '.env.backenddatapath=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "/root" '.env.backendinstallpath=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "${BACKEND_AUTHRPC:-$(jq -r .ports.backend_authrpc <<< $CLIENT_CONFIG)}" '.ports.backendauthrpc=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "${BACKEND_HTTP:-$(jq -r .ports.backend_http <<< $CLIENT_CONFIG)}" '.ports.backendhttp=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "${BACKEND_P2P:-$(jq -r .ports.backend_p2p <<< $CLIENT_CONFIG)}" '.ports.backendp2p=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "${RPC_PORT:-$(jq -r .ports.backend_rpc <<< $CLIENT_CONFIG)}" '.ports.backendrpc=$value' /root/consensus.json)" > /root/consensus.json
    echo "$(jq -r --arg value "${CONSENSUS_URL:-$(jq -r .backend.binary_url <<< $CLIENT_CONFIG)}" '.bin_url=$value' /root/consensus.json)" > /root/consensus.json
  fi
}
if [[ -f /usr/local/bin/beacon-chain ]]; then
 VERSION=($(beacon-chain -v))
 echo -e "---------------------------------------------------------------"
 echo -e "| CONSENSUS CLIENT LUNCHER v1.0"
 echo -e "---------------------------------------------------------------"
 echo -e "| CLIENT: ${VERSION[2]}"
 bash -c "$(jq -r .cmd_consensus /root/consensus.json)"
 exit
fi
sleep 60
echo -e "---------------------------------------------------"
echo -e "| Checking consensus client requriment ${COIN}..."
if [[ "$BLOCKBOOKGIT_URL" == "" ]]; then
  BLOCKBOOKGIT_URL="https://github.com/trezor/blockbook.git"
fi
echo -e "| GITHUB URL: $BLOCKBOOKGIT_URL"
re="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
if [[ $BLOCKBOOKGIT_URL =~ $re ]]; then
  GIT_USER=${BASH_REMATCH[4]}
  REPO=$(cut -d "." -f 1 <<< ${BASH_REMATCH[5]})
fi
RAW_CONSENSUS_URL="https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/coins/${COIN}_consensus.json"
CLIENT_CONFIG=$(curl -SsL $RAW_CONSENSUS_URL 2>/dev/null | jq .  2>/dev/null)
if [[ $(jq -r . 2>/dev/null <<< "$CLIENT_CONFIG") == "" || $(jq -r . 2>/dev/null <<< "$CLIENT_CONFIG") == "null" ]]; then
  echo -e "| CONSENSUS CLIENT: Not required (EXIT)"
  echo -e "---------------------------------------------------"
  exit
fi
echo -e "| CONSENSUS CONFIG: $RAW_CONSENSUS_URL"
create_consensus_config
parse_template "$CLIENT_CONFIG" "cmd_consensus" "consensus" "consensus"
mkdir -p /root/${COIN}_consensus/backend 2>/dev/null

if [[ ! -f /usr/local/bin/beacon-chain ]]; then
  cd /tmp
  BEACON_URL=$(jq -r .bin_url /root/consensus.json 2>/dev/null)
  echo -e "| BEACON_URL: $BEACON_URL"
  curl -SsL --create-dirs -o /tmp/backend/beacon-chain $BEACON_URL
  #wget -q --show-progress -c -t 5 $DAEMON_URL -o /backend/beacon-chain
  echo -e "| Installing consensus client ($COIN)..."
  install -m 0755 -o root -g root -t /usr/local/bin backend/*
  rm -rf /tmp/*
fi
 VERSION=($(beacon-chain -v))
 echo -e "---------------------------------------------------------------"
 echo -e "| CLIENT: ${VERSION[2]}"
 bash -c "$(jq -r .cmd_consensus /root/consensus.json)"
