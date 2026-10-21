#!/usr/bin/env bash
server_offline="0"
failed_counter="0"
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
RPC_PORT_KEY=${RPC_PORT_KEY:-rpcport}
RPC_USER_KEY=${RPC_USER_KEY:-rpcuser}
RPC_PASSWORD_KEY=${RPC_PASSWORD_KEY:-rpcpassword}
COIN_CONFIG=/opt/blockbook/configs/coins/$COIN.json

# Removes only the settings that would fork the daemon away from supervisord.
# The previous version deleted every line *containing* "mainnet" or "daemon",
# which breaks TOML configs such as zebra's (initial_mainnet_peers = [...]).
function config_clean(){
 sed -i -E '/^[[:space:]]*(daemon|mainnet)[[:space:]]*=/d' /root/${CONFIG_DIR}/${CONFIG_FILE}.conf
 if [ "$REMOVE_ADDNODES" = "true" ]; then
   sed -i '/^addnode=/d' /root/${CONFIG_DIR}/${CONFIG_FILE}.conf
 fi
 # Pruned backend (see prune.sh): manual pruning, which rules out txindex.
 if [ "$PRUNE_BACKEND" = "1" ]; then
   sed -i -E '/^[[:space:]]*(txindex|prune)[[:space:]]*=/d' /root/${CONFIG_DIR}/${CONFIG_FILE}.conf
   sed -i '1i prune=1' /root/${CONFIG_DIR}/${CONFIG_FILE}.conf
 fi
}

function config_create(){
if [[ "$DAEMON_CONFIG" != "AUTO" ]]; then
 echo -e "| Creating config file..."
 cat <<- EOF > /root/$CONFIG_DIR/$CONFIG_FILE.conf
 txindex=1
 $RPC_PORT_KEY=$RPC_PORT
 $RPC_USER_KEY=$RPC_USER
 $RPC_PASSWORD_KEY=$RPC_PASS
EOF
 else
   echo -e "| Awaiting for daemon config generate by blockbook..."
   while [[ ! -f /root/$CONFIG_DIR/$CONFIG_FILE.conf ]]; do
     sleep 10
   done
   config_clean
 fi
}

function parse_template(){
 echo -e "| Parsing exec command template..."
 TEMPLATE=$(jq -r .backend.exec_command_template <<< "$1")
 BIN_PATH=($TEMPLATE)
 if [[ ! $(grep "/bin/sh -c" <<< $TEMPLATE) ]]; then
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
 # -pid points at /run/<coin>/, which does not exist in the container.
 TEMPLATE=$(sed -E "s# -pid=[^ ]+##" <<< $TEMPLATE)
 if [[ ! -f /root/$3.json ]]; then
   echo "{}" > /root/$3.json
 fi
 echo "$(jq -r --arg key "$2" --arg value "$TEMPLATE" '.[$key]=$value' /root/$3.json)" > /root/$3.json
 echo -e "| RUN CMD: $(jq -r .$2 /root/$3.json)"
}

function extract_daemon() {
  mkdir -p /tmp/backend
  cd /tmp
  echo -e "| Searching params script..."
  PARAMS_CHECK=$(bsdtar -tvf ${DAEMON_URL##*/} | grep '\-params' | head -n1)
  if [[ "$PARAMS_CHECK" != "" ]]; then
    STRIP=$(bsdtar -tvf ${DAEMON_URL##*/} | egrep '\-params$|\-params.sh$' | head -n1 | awk '{ printf "%s\n", $9 }' | awk -F\/ '{print NF-1}')
    bsdtar -C backend --strip $STRIP -xf ${DAEMON_URL##*/} > /dev/null 2>&1
    PARAMS_PATH=$(find /tmp -not -path "*/share/*" -not -path "*/man/*" -type f -iname "*\-params*" | head -n1)
    if [[ $PARAMS_PATH != "" ]]; then
      echo -e "| FOUND: $PARAMS_PATH..."
      chmod +x $PARAMS_PATH
      echo -e "| Lunching ${PARAMS_PATH##*/}...."
      cd backend
      bash -c $PARAMS_PATH > /dev/null 2>&1
      cd /tmp
    fi
    rm -rf /tmp/backend/*
  fi
  echo -e "| Unpacking daemon bin archive file..."
  strip_lvl=$(bsdtar -tvf ${DAEMON_URL##*/} | grep ${BINARY_NAME}$ | awk '{ printf "%s\n", $9 }' | awk -F\/ '{print NF-1}')
  bsdtar --exclude="share" --exclude="lib" --exclude="include" -C backend --strip $strip_lvl -xf ${DAEMON_URL##*/} > /dev/null 2>&1 || return 1
  return 0
}

function cli_search(){
  if [[ "$CLI_NAME" == "" ]]; then
    echo -e "| Searching for CLI binary..."
    CLI_PATH=$(find /usr/local/bin/ -type f -iname "*-cli" | tail -n1)
    if [[ "$CLI_PATH" != "" ]]; then
      CLI_NAME="${CLI_PATH##*/}"
      echo "$(jq -r --arg key "cli_name" --arg value "$CLI_NAME" '.[$key]=$value' /root/daemon_config.json)" > /root/daemon_config.json
    fi
  fi
}

function tar_file_unpack()
{
    echo -e "| Unpacking bootstrap archive file..."
    pv -f -i 60 $1 2>&1 | tar -zx -C $2
}

function cdn_speedtest() {
        if [[ -z $1 || "$1" == "0" ]]; then
                BOOTSTRAP_FILE="daemon_bootstrap.tar.gz"
        else
                BOOTSTRAP_FILE="$1"
        fi
        if [[ -z $2 || "$2" == "0" ]]; then
                dTime="5"
        else
                dTime="$2"
        fi
        if [[ -z $3 || "$3" == "0" ]]; then
                rand_by_domain=("1" "2" "3" "4" "5" "6" "7")
        else
                msg="$3"
                shift
                shift
                rand_by_domain=("$@")
                custom_url="1"
        fi
        size_list=()
        i=0
        len=${#rand_by_domain[@]}
        echo -e "| Running quick download speed test for ${BOOTSTRAP_FILE}, Servers: $len"
        while [ $i -lt $len ]; do
                if [[ "$custom_url" == "1" ]]; then
                        testing=$(curl -L -m ${dTime} ${rand_by_domain[$i]}${BOOTSTRAP_FILE}  --output testspeed -fail --silent --show-error 2>&1)
                else
                        testing=$(curl -L -m ${dTime} https://cdn-${rand_by_domain[$i]}.runonflux.io/apps/fluxshare/getfile/${BOOTSTRAP_FILE}  --output testspeed -fail --silent --show-error 2>&1)
                fi
                testing_size=$(grep -Po "\d+" <<< "$testing" | paste - - - - | awk '{printf  "%d\n",$3}')
                testing_size=${testing_size:-0}
                echo -e "| - server ${rand_by_domain[$i]} - bytes downloaded: $testing_size"
                size_list+=($testing_size)
                if [[ "$testing_size" == "0" ]]; then
                        failed_counter=$(($failed_counter+1))
                fi
                i=$(($i+1))
        done
        rServerList=$((${#size_list[@]}-$failed_counter))
        rm -rf testspeed > /dev/null 2>&1
        if [[ "$rServerList" == "0" ]]; then
        server_offline="1"
        return
        fi
        arr_max=$(printf '%s\n' "${size_list[@]}" | sort -n | tail -1)
        for i in "${!size_list[@]}"; do
                [[ "${size_list[i]}" == "$arr_max" ]] &&
                max_indexes+=($i)
        done
        server_index=${rand_by_domain[${max_indexes[0]}]}
        if [[ "$custom_url" == "1" ]]; then
                BOOTSTRAP_URL="$server_index"
        else
                BOOTSTRAP_URL="https://cdn-${server_index}.runonflux.io/apps/fluxshare/getfile/"
        fi
        DOWNLOAD_URL="${BOOTSTRAP_URL}${BOOTSTRAP_FILE}"
        echo -e "| Best server: $DOWNLOAD_URL"
}

stop_script() {
  echo -e "| Stopping daemon (EXIT)..."
  if [[ "$BINARY_NAME" != "" ]]; then
    pkill -TERM -x "$BINARY_NAME"
    for i in $(seq 1 280); do pgrep -x "$BINARY_NAME" > /dev/null || break; sleep 1; done
  fi
  exit 0
}

trap stop_script SIGINT SIGTERM

if [[ "$DAEMON" != "1" ]]; then
  echo -e "| DAEMON LAUNCHER [DISABLED]..."
  # Stay up so supervisord does not restart this every few seconds.
  exec sleep infinity
fi

echo -e "| DAEMON LAUNCHER v3 [$(date '+%Y-%m-%d %H:%M:%S')]"
echo -e "---------------------------------------------------------------------------"
until [[ -f /run/bb/prepared && -f /run/bb/bootstrapped ]]; do
  sleep 10
done

BLOCKBOOKCONFIG=$(jq . $COIN_CONFIG)

if [[ -f /root/daemon_config.json ]]; then
  echo -e "| Loading daemon_config.json..."
  if [[ "$CLI_NAME" == "" ]]; then
    CLI_NAME=$(jq -r '.cli_name // empty' /root/daemon_config.json)
  fi
  if [[ "$BINARY_NAME" == "" ]]; then
    BINARY_NAME=$(jq -r '.binary_name // empty' /root/daemon_config.json)
  fi
fi
# The daemon version is the one pinned in the image's coin config unless the
# app spec sets DAEMON_URL. A URL saved by an older container is ignored on
# purpose: that is how instances stayed on old daemon versions.
if [[ "$DAEMON_URL" == "" ]]; then
  DAEMON_URL=$(jq -r '.backend.binary_url // empty' <<< "$BLOCKBOOKCONFIG")
fi

if [[ "$CONFIG" == "1" ]]; then
  if [[ ! -f /root/$CONFIG_DIR/$CONFIG_FILE.conf ]]; then
   mkdir -p /root/$CONFIG_DIR
   config_create
   if [[ "$EXTRACONFIG" != "" ]]; then
    echo -e "$EXTRACONFIG" >> /root/$CONFIG_DIR/$CONFIG_FILE.conf
   fi
 fi
fi

if [[ "$BOOTSTRAP" == "1" && ! -f /root/BOOTSTRAP_LOCKED ]]; then
  if [[ "$CONFIG" == "AUTO" ]]; then BOOTSTRAP_DIR=/root/$CONFIG_DIR/backend; else BOOTSTRAP_DIR=/root/$CONFIG_DIR; fi
  # Never unpack over a chain that is already there.
  if [[ -d $BOOTSTRAP_DIR/blocks && $(du -sm $BOOTSTRAP_DIR/blocks | cut -f1) -gt 1024 ]]; then
    echo -e "| Bootstrap skipped, $BOOTSTRAP_DIR already holds a chain"
    echo -e "Bootstrap [LOCKED]" > /root/BOOTSTRAP_LOCKED
  else
    B_FILE="${B_FILE:-0}"
    B_TIMEOUT="${B_TIMEOUT:-6}"
    B_SERVERS_LIST="${B_SERVERS_LIST:-0}"
    cdn_speedtest "$B_FILE" "$B_TIMEOUT" "${B_SERVERS_LIST[@]}"
    if [[ "$server_offline" == "1" ]]; then
      echo -e "| All bootstrap servers offline, starting without bootstrap"
    else
      cd /root
      start_download=`date +%s`
      echo -e "| Downloading file: $DOWNLOAD_URL"
      if wget --tries 5 -O $BOOTSTRAP_FILE $DOWNLOAD_URL -q; then
        mkdir -p $BOOTSTRAP_DIR
        tar_file_unpack "/root/$BOOTSTRAP_FILE" "$BOOTSTRAP_DIR" && echo -e "Bootstrap [LOCKED]" > /root/BOOTSTRAP_LOCKED
        echo -e "| Bootstrapping took $((($(date +%s)-$start_download)/60)) min."
      else
        echo -e "| Bootstrap download failed, starting without bootstrap"
      fi
      rm -rf /root/$BOOTSTRAP_FILE
   fi
 fi
fi
touch /run/bb/daemon_bootstrap_done

if [[ "$BINARY_NAME" != "" ]]; then
  echo -e "| Stopping daemon (START)..."
  pkill -9 -x "$BINARY_NAME"
fi

if [[ ! -f /root/blockbook.json ]]; then
  echo -e "| Creating blockbook.json file..."
  cat << EOF > /root/blockbook.json
{
  "coin": {
    "alias": "$COIN"
  },
  "env": {
    "backenddatapath": "/root",
    "backendinstallpath": "/root",
    "rpcbindhost": "127.0.0.1",
    "rpcallowip": "127.0.0.1"
  },
  "ports": {
    "backendauthrpc": "${BACKEND_AUTHRPC:-$(jq -r .ports.backend_authrpc <<< $BLOCKBOOKCONFIG)}",
    "backendhttp": "${BACKEND_HTTP:-$(jq -r .ports.backend_http <<< $BLOCKBOOKCONFIG)}",
    "backendp2p": "${BACKEND_P2P:-$(jq -r .ports.backend_p2p <<< $BLOCKBOOKCONFIG)}",
    "backendrpc": "${RPC_PORT:-$(jq -r .ports.backend_rpc <<< $BLOCKBOOKCONFIG)}"
  },
  "geth": {
    "init_url": "${INIT_URL:-$(jq -r .backend.geth_init_url <<< $BLOCKBOOKCONFIG)}",
    "static_nodes_url": "${STATIC_NODE_URL:-$(jq -r .backend.static_nodes_url <<< $BLOCKBOOKCONFIG)}"
  }
}
EOF
fi

if [[ "$BINARY_NAME" == "" ]]; then
  BINARY_NAME=$(jq -r .backend.exec_command_template 2>/dev/null <<< "$BLOCKBOOKCONFIG")
  BINARY_NAME=($(sed "s|/bin/sh -c '{{.Env.BackendInstallPath}}/{{.Coin.Alias}}/|""|" <<< $BINARY_NAME))
  BINARY_NAME=${BINARY_NAME##*/}
fi
if [[ ! -f /root/daemon_config.json ]]; then
  echo "{}" > /root/daemon_config.json
fi
echo "$(jq -r --arg b "$BINARY_NAME" --arg u "$DAEMON_URL" '.binary_name=$b | .daemon_url=$u' /root/daemon_config.json)" > /root/daemon_config.json
if [[ $(jq -r .cmd /root/daemon_config.json 2>/dev/null) == "null" && "$CONFIG" == "AUTO" ]]; then
  parse_template "$BLOCKBOOKCONFIG" "cmd" "daemon_config" "blockbook"
fi

if [[ ! -f /usr/local/bin/$BINARY_NAME ]]; then
  if [[ "$DAEMON_URL" == "" || "$DAEMON_URL" == "null" ]]; then
    echo -e "| No download URL for $COIN daemon ($BINARY_NAME) and it is not in the image, cannot start"
    exec sleep infinity
  fi
  echo -e "| Downloading daemon ($COIN): $DAEMON_URL"
  mkdir -p /tmp/backend && cd /tmp
  wget -q -c -t 5 $DAEMON_URL
  extract_daemon
  echo -e "| Installing daemon ($COIN)..."
  install -m 0755 -o root -g root -t /usr/local/bin backend/*
  rm -rf /tmp/*
  if [[ ! -f /usr/local/bin/$BINARY_NAME ]]; then
    echo -e "| $BINARY_NAME not found in $DAEMON_URL"
    sleep 300
    exit 1
  fi
fi
cli_search
cd /
sleep 5

if [[ "$CONFIG" == "0" || "$CONFIG" == "" ]]; then
  echo -e "| Starting $COIN daemon (Config: DISABLED)..."
  exec ${BINARY_NAME} ${CLIFLAGS}
fi
if [[ "$CONFIG" == "1" ]]; then
  echo -e "| Starting $COIN daemon (Config: ENABLED)..."
  exec ${BINARY_NAME} -datadir="/root/${CONFIG_DIR}" -conf="/root/${CONFIG_DIR}/${CONFIG_FILE}.conf"
fi
if [[ "$CONFIG" == "AUTO" ]]; then
  if [[ ! -f /root/$CONFIG_DIR/$CONFIG_FILE.conf || -f /root/$CONFIG_DIR/.conf_fresh ]]; then
    mkdir -p /root/$CONFIG_DIR > /dev/null 2>&1
    config_create
    if [[ "$EXTRACONFIG" != "" ]]; then
      echo -e "$EXTRACONFIG" >> /root/$CONFIG_DIR/$CONFIG_FILE.conf
    fi
    rm -f /root/$CONFIG_DIR/.conf_fresh
  fi
  echo -e "| Starting $COIN daemon (Config: AUTO)..."
  mkdir -p /root/$CONFIG_DIR/backend > /dev/null 2>&1
  init_url=$(jq -r .geth.init_url /root/blockbook.json)
  if [[ "$init_url" != "" && "$init_url" != "null" ]]; then
    if [[ ! -f /root/geth_init.json ]]; then
      echo -e "| Downloading init file, URL: $init_url"
      wget "$init_url" -O /root/geth_init.json > /dev/null 2>&1
      echo -e "| Tiggering geth init..."
      geth --datadir /root/$COIN/backend init /root/geth_init.json
      static_nodes_url=$(jq -r .geth.static_nodes_url /root/blockbook.json)
      if [[ "$static_nodes_url" != "" && "$static_nodes_url" != "null" ]]; then
        echo -e "| Downloading static node file, URL: $static_nodes_url"
        wget "$static_nodes_url" -O /root/$COIN/backend/geth/static-nodes.json
      fi
    fi
  fi
  # Run in the background and wait, so the TERM trap above can stop the
  # daemon cleanly instead of supervisord killing the whole group.
  bash -c "$(jq -r .cmd /root/daemon_config.json)" &
  wait $!
fi
