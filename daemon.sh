#!/usr/bin/env bash
server_offline="0"
failed_counter="0"
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
RPC_PORT_KEY=${RPC_PORT_KEY:-rpcport}
RPC_USER_KEY=${RPC_USER_KEY:-rpcuser}
RPC_PASSWORD_KEY=${RPC_PASSWORD_KEY:-rpcpassword}

function config_clean(){
 REMOVED_LIST=( "mainnet" "daemon" )
 REMOVED_LENGTH=${#REMOVED_LIST[@]}
 for (( p=0; p<${REMOVED_LENGTH}; p++ ));
 do
   sed -i "/$(grep -e ${REMOVED_LIST[$p]} /root/${CONFIG_DIR}/${CONFIG_FILE}.conf)/d" /root/${CONFIG_DIR}/${CONFIG_FILE}.conf > /dev/null 2>&1
 done
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
   while true; do
     if [[ -f /root/$CONFIG_DIR/$CONFIG_FILE.conf ]]; then
       config_clean
       sleep 5
       break
     fi
     sleep 180
   done
 fi
}

function parse_template(){
 echo -e "| Parsing exec command template..."
 TEMPLATE=$(jq -r .backend.exec_command_template <<< "$1")
 BIN_PATH=($TEMPLATE)
 DATA_PATH=${BIN_PATH[1]}
 CONF_PATH=${BIN_PATH[2]}
 if [[ ! $(grep "/bin/sh -c" <<< $TEMPLATE) ]]; then
   #TEMPLATE="$BIN_PATH $DATA_PATH $CONF_PATH"
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
 TEMPLATE=$(sed "s/run/root/g" <<< $TEMPLATE)
 if [[ ! -f /root/$3.json ]]; then
   echo "{}" > /root/$3.json
 fi
 echo "$(jq -r --arg key "$2" --arg value "$TEMPLATE" '.[$key]=$value' /root/$3.json)" > /root/$3.json
 echo -e "| RUN CMD: $(jq -r .$2 /root/$3.json)"
}

function extract_daemon() {
  if [[ ! -d /tmp/backend ]]; then
    echo -e "| Creating directory..."
    mkdir -p /tmp/backend
  fi
  cd /tmp
  echo -e "| Searching params script..."
  PARAMS_CHECK=$(bsdtar -ztvf ${DAEMON_URL##*/} |  grep '\-params' | head -n1)
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
  echo -e "| ${CYAN}Unpacking daemon bin archive file...${NC}"
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
    echo -e "| ${CYAN}Unpacking bootstrap archive file...${NC}"
    pv $1 | tar -zx -C $2
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
                rand_by_domain=("5" "6" "7" "8" "9" "10" "11" "12")
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
        echo -e "| ${CYAN}Running quick download speed test for ${BOOTSTRAP_FILE}, Servers: ${GREEN}$len${NC}"
        start_test=`date +%s`
        while [ $i -lt $len ];
   do
                if [[ "$custom_url" == "1" ]]; then
                        testing=$(curl -m ${dTime} ${rand_by_domain[$i]}${BOOTSTRAP_FILE}  --output testspeed -fail --silent --show-error 2>&1)
                else
                        testing=$(curl -m ${dTime} http://cdn-${rand_by_domain[$i]}.runonflux.io/apps/fluxshare/getfile/${BOOTSTRAP_FILE}  --output testspeed -fail --silent --show-error 2>&1)
                fi
                testing_size=$(grep -Po "\d+" <<< "$testing" | paste - - - - | awk '{printf  "%d\n",$3}')
                mb=$(bc <<<"scale=2; $testing_size / 1048576 / $dTime" | awk '{printf "%2.2f\n", $1}')
                if [[ "$custom_url" == "1" ]]; then
                        domain=$(sed -e 's|^[^/]*//||' -e 's|/.*$||' <<< ${rand_by_domain[$i]})
                        echo -e "| - ${GREEN}URL - ${YELLOW}${domain}${GREEN} - Bits Downloaded: ${YELLOW}$testing_size${NC} ${GREEN}Average speed: ${YELLOW}$mb ${GREEN}MB/s${NC}"
                else
                        echo -e "| - ${GREEN}cdn-${YELLOW}${rand_by_domain[$i]}${GREEN} - Bits Downloaded: ${YELLOW}$testing_size${NC} ${GREEN}Average speed: ${YELLOW}$mb ${GREEN}MB/s${NC}"
                fi
                size_list+=($testing_size)
                if [[ "$testing_size" == "0" ]]; then
                        failed_counter=$(($failed_counter+1))
                fi
                i=$(($i+1))
        done
        rServerList=$((${#size_list[@]}-$failed_counter))
        echo -e "| ${CYAN}Valid servers: ${GREEN}${rServerList} ${CYAN}- Duration: ${GREEN}$((($(date +%s)-$start_test)/60)) min. $((($(date +%s)-$start_test) % 60)) sec.${NC}"
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
                BOOTSTRAP_URL="http://cdn-${server_index}.runonflux.io/apps/fluxshare/getfile/"
        fi
        DOWNLOAD_URL="${BOOTSTRAP_URL}${BOOTSTRAP_FILE}"
        mb=$(bc <<<"scale=2; $arr_max / 1048576 / $dTime" | awk '{printf "%2.2f\n", $1}')
        if [[ "$custom_url" == "1" ]]; then
                domain=$(sed -e 's|^[^/]*//||' -e 's|/.*$||' <<< ${server_index})
                echo -e "| ${CYAN}Best server is: ${YELLOW}${domain} ${GREEN}Average speed: ${YELLOW}$mb ${GREEN}MB/s${NC}"
        else
                echo -e "| ${CYAN}Best server is: ${GREEN}cdn-${YELLOW}${rand_by_domain[${max_indexes[0]}]} ${GREEN}Average speed: ${YELLOW}$mb ${GREEN}MB/s${NC}"
        fi
}

stop_script() {
  echo -e "| Stopping daemon (EXIT)..."
  if [[ "$CLI_NAME" != "" ]]; then
    timeout 10 ${CLI_NAME} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} stop > /dev/null 2>&1
    timeout 10 ${CLI_NAME} -conf /root/$CONFIG_DIR/$CONFIG_FILE stop > /dev/null 2>&1
  fi
  if [[ "$BINARY_NAME" != "" ]]; then
    kill -9 $(ps -ef | grep $BINARY_NAME | tr -s ' ' | cut -d ' ' -f2 | head -n1)
  fi
  exit 0
}

trap stop_script SIGINT SIGTERM

if [[ "$DAEMON" == "1" ]]; then
echo -e "| DAEMON LUNCHER v1.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
echo -e "---------------------------------------------------------------------------"

if [[ -f /root/daemon_config.json ]]; then
  echo -e "| Loading daemon_config.json..."
  if [[ "$CLI_NAME" == "" ]]; then
    CLI_NAME=$(jq -r .cli_name /root/daemon_config.json)
  fi
  if [[ "$BINARY_NAME" == "" ]]; then
    BINARY_NAME=$(jq -r .binary_name /root/daemon_config.json)
  fi
  if [[ $(jq -r .daemon_url /root/daemon_config.jso) != "null" && $(jq -r .daemon_url /root/daemon_config.jso) != "" ]]; then
    DAEMON_URL=$(jq -r .daemon_url /root/daemon_config.json)
  fi
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
    B_FILE="${B_FILE:-0}"
    B_TIMEOUT="${B_TIMEOUT:-6}"
    B_SERVERS_LIST="${B_SERVERS_LIST:-0}"

    cdn_speedtest "$B_FILE" "$B_TIMEOUT" "${B_SERVERS_LIST[@]}"
    if [[ "$server_offline" == "1" ]]; then
      echo -e "| ${CYAN}All Bootstrap server offline, operation aborted.. ${NC}" && sleep 1
    else
      cd /root
      start_download=`date +%s`
      echo -e "| ${YELLOW}Downloading File: ${GREEN}$DOWNLOAD_URL ${NC}"
      wget --tries 5 -O $BOOTSTRAP_FILE $DOWNLOAD_URL -q --no-verbose --show-progress --progress=dot:giga > /dev/null 2>&1
      echo -e "| Download duration: $((($(date +%s)-$start_download)/60)) min. $((($(date +%s)-$start_download) % 60)) sec."
      start_unzip=`date +%s`
      if [[ "$CONFIG" == "AUTO" ]]; then
        mkdir -p /root/$CONFIG_DIR/backend  > /dev/null 2>&1
        tar_file_unpack "/root/$BOOTSTRAP_FILE" "/root/$CONFIG_DIR/backend"
      else
        mkdir -p /root/$CONFIG_DIR  > /dev/null 2>&1
        tar_file_unpack "/root/$BOOTSTRAP_FILE" "/root/$CONFIG_DIR"
      fi
      echo -e "| Unzip duration: $((($(date +%s)-$start_unzip)/60)) min. $((($(date +%s)-$start_unzip) % 60)) sec."
      echo -e "| Bootstraping duration: $((($(date +%s)-$start_download)/60)) min. $((($(date +%s)-$start_download) % 60)) sec."
      echo -e "Bootstrap [LOCKED]" > BOOTSTRAP_LOCKED
      rm -rf /root/$BOOTSTRAP_FILE
      sleep 2
   fi
 fi

if [[ "$BINARY_NAME" != "" ]]; then
  echo -e "| Stopping daemon (START)..."
  if [[ "$CLI_NAME" != "" ]]; then
    timeout 10 ${CLI_NAME} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} stop > /dev/null 2>&1
    timeout 10 ${CLI_NAME} -conf=/root/$CONFIG_DIR/$CONFIG_FILE  stop > /dev/null 2>&1
  fi
    kill -9 $(ps -ef | grep $BINARY_NAME | tr -s ' ' | cut -d ' ' -f2 | head -n1)
fi

if [[ ! -f /usr/local/bin/$BINARY_NAME ]]; then
  echo -e "| Downloading daemon ($COIN)..."
  cd /tmp
  mkdir backend
   echo -e "| Fetching Blockbook config for $COIN..."
  if [[ "$BLOCKBOOKGIT_URL" == "" ]]; then
    BLOCKBOOKGIT_URL="https://github.com/trezor/blockbook.git"
  fi
  echo -e "| GITHUB URL: $BLOCKBOOKGIT_URL"
  re="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
  if [[ $BLOCKBOOKGIT_URL =~ $re ]]; then
    GIT_USER=${BASH_REMATCH[4]}
    REPO=$(cut -d "." -f 1 <<< ${BASH_REMATCH[5]})
  fi
  RAW_CONF_URL="https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/coins/$COIN.json"
  echo -e "| CONFIG URL: $RAW_CONF_URL"
  BLOCKBOOKCONFIG=$(curl -SsL $RAW_CONF_URL 2>/dev/null | jq .)
  if [[ ! -f /root/blockbook.json ]]; then
    echo -e "| Creating blockbook.json file..."
    cat << EOF > /root/blockbook.json
{
  "coin": {
    "alias": "$COIN"
  },
  "env": {
    "backenddatapath": "/root",
    "backendinstallpath": "/root"
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
  if [[ "$DAEMON_URL" == "" ]]; then
      DAEMON_URL=$(jq -r .backend.binary_url <<< "$BLOCKBOOKCONFIG")
  fi
  if [[ "$BINARY_NAME"  == "" ]]; then
    BINARY_NAME=$(jq -r .backend.exec_command_template 2>/dev/null <<< "$BLOCKBOOKCONFIG")
    BINARY_NAME=($(sed "s|/bin/sh -c '{{.Env.BackendInstallPath}}/{{.Coin.Alias}}/|""|" <<< $BINARY_NAME))
    BINARY_NAME=${BINARY_NAME##*/}
    if [[ ! -f /root/daemon_config.json ]]; then
      echo "{}" > /root/daemon_config.json
      echo "$(jq -r --arg key "binary_name" --arg value "$BINARY_NAME" '.[$key]=$value' /root/daemon_config.json)" > /root/daemon_config.json
      echo "$(jq -r --arg key "daemon_url" --arg value "$DAEMON_URL" '.[$key]=$value' /root/daemon_config.json)" > /root/daemon_config.json
    fi
  fi
  if [[ $(jq -r .cmd /root/daemon_config.json 2>/dev/null) == "null" && "$CONFIG" == "AUTO" ]]; then
    ################ PARSE DAEMON EXEC TEMPLATE ######################
    parse_template "$BLOCKBOOKCONFIG" "cmd" "daemon_config" "blockbook"
    ##################################################################
  fi

  if [[ ! -f /usr/local/bin/$BINARY_NAME ]]; then
    echo -e "| BINARY URL: $DAEMON_URL"
    wget -q --show-progress -c -t 5 $DAEMON_URL
    extract_daemon
    echo -e "| Installing daemon ($COIN)..."
    install -m 0755 -o root -g root -t /usr/local/bin backend/*
    rm -rf /tmp/*
    if [[ "$CLI_NAME" == "" ]]; then
      if [[ ! -f /root/daemon_config.json ]]; then
        echo "{}" > /root/daemon_config.json
      fi
      cli_search
    fi
  fi

fi
cd /
sleep 5

#if [[ "$FETCH_FILE" != "" ]]; then
#  if [[ ! -d /root/.zcash-params ]]; then
#    echo -e "| Installing fetch-params..."
#    bash -c "$FETCH_FILE" > /dev/null 2>&1 && sleep 2
#  fi
#fi

if [[ "$CONFIG" == "0" || "$CONFIG" == "" ]]; then
  echo -e "| Starting $COIN daemon (Config: DISABLED)..."
  ${BINARY_NAME} ${CLIFLAGS}
fi
if [[ "$CONFIG" == "1" ]]; then
  echo -e "| Starting $COIN daemon (Config: ENABLED)..."
  ${BINARY_NAME} -datadir="/root/${CONFIG_DIR}" -conf="/root/${CONFIG_DIR}/${CONFIG_FILE}.conf"
fi
if [[ "$CONFIG" == "AUTO" ]]; then
 CLEAN_CHECK=$(grep 'daemon=' /root/${CONFIG_DIR}/${CONFIG_FILE}.conf)
 if [[ ! -f /root/$CONFIG_DIR/$CONFIG_FILE.conf || "$CLEAN_CHECK" != "" ]]; then
   mkdir -p /root/$CONFIG_DIR > /dev/null 2>&1
   config_create
   if [[ "$EXTRACONFIG" != "" ]]; then
     echo -e "$EXTRACONFIG" >> /root/$CONFIG_DIR/$CONFIG_FILE.conf
   fi
 fi
  echo -e "| Starting $COIN daemon (Config: AUTO)..."
  if [[ ! -d /root/$CONFIG_DIR/backend ]]; then
    mkdir -p /root/$CONFIG_DIR/backend > /dev/null 2>&1
  fi
   
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
   bash -c "$(jq -r .cmd /root/daemon_config.json)"
fi
echo -e "---------------------------------------------------------------------------"
else
  echo -e "| DAEMON LUNCHER [DISABLED]..."
  echo -e "---------------------------------------------------------------------------"
  exit
fi
