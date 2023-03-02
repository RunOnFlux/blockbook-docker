#!/bin/bash
set +o history
trap close EXIT
function close(){
  if [[ $(set -o | grep history) == *"off"* ]]; then
    set -o history
  fi
}

if jq --version > /dev/null 2>&1; then
  sleep 1
else
  sudo apt install jq whiptail -y  > /dev/null 2>&1
fi

function coin_list(){
  if [[ "$1" == "" ]]; then
    BLOCKBOOKGIT_URL="https://github.com/trezor/blockbook/tree/master/configs/coins"
  else
    BLOCKBOOKGIT_URL="$1"
  fi
  echo -e "--------------------------------------------------------------------------------------"
  echo -e "| Blockbook Docker Manager v2.0"
  echo -e "--------------------------------------------------------------------------------------"
  COIN_LIST=$(curl -SsL $BLOCKBOOKGIT_URL | grep -oP '(?<=title=").*(?=.json" data)')
  COIN_EXCLUDE=$(egrep -v 'consensus|testnet|regtest|test|archive|signet' <<< $COIN_LIST)
  COIN_FOUND=$(wc -l <<< $COIN_EXCLUDE)
  echo -e "$COIN_EXCLUDE"
  echo -e "--------------------------------------------------------------------------------------"
  echo -e "| URL: $BLOCKBOOKGIT_URL, FOUND: $COIN_FOUND"
  echo -e "--------------------------------------------------------------------------------------"
}

function setup(){
 BLOCKBOOKGIT_URL="$(whiptail --title "BLOCKBOOK DOCKER MANAGER v1.0" --inputbox "Enter your Githab  Repository" 8 72 3>&1 1>&2 2>&3)"
 TAG="$(whiptail --title "BLOCKBOOK DOCKER MANAGER v1.0" --inputbox "Enter your Githab Branch" 8 72 3>&1 1>&2 2>&3)"
 DAEMON_URL="$(whiptail --title "BLOCKBOOK DOCKER MANAGER v1.0" --inputbox "Enter your daemon binary URL" 8 72 3>&1 1>&2 2>&3)"
 if [[ "$BLOCKBOOKGIT_URL" == "" ]]; then
    BLOCKBOOKGIT_URL="https://github.com/trezor/blockbook.git"
 fi
 if [[ "$TAG" == "" ]]; then
    TAG="master"
 fi
 echo -e "---------------------------------------------------------------------------------------"
 echo -e "| GITHUB URL: $BLOCKBOOKGIT_URL, BRANCH: $TAG"
 re="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
 if [[ $BLOCKBOOKGIT_URL =~ $re ]]; then
   GIT_USER=${BASH_REMATCH[4]}
   REPO=$(cut -d "." -f 1 <<< ${BASH_REMATCH[5]})
 fi
 RAW_CONF_URL="https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/coins/$COIN.json"
 G_V=($(curl -SsL https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/build/docker/bin/Dockerfile | egrep "ENV GOLANG_VERSION|ENV ROCKSDB_VERSION"))
 if [[ "$G_V" != "" ]]; then
   #if [[ ${G_V[1]##*=} != "go1.19.2" ]]; then
   #  flage="-e GOLANG_VERSION=${G_V[1]##*=}"
   #fi
   if [[ ${G_V[3]##*=} != "v7.7.2" ]]; then
    flage="$flage -e ROCKSDB_VERSION=${G_V[3]##*=}"
   fi
   if [[ $BLOCKBOOKGIT_URL != "https://github.com/trezor/blockbook.git" ]]; then
     flage="$flage -e BLOCKBOOKGIT_URL=$BLOCKBOOKGIT_URL"
   fi

   if [[ $TAG != "master" ]]; then
     flage="$flage -e TAG=$TAG"
   fi
   if [[ $DAEMON_URL != "" ]]; then
     flage="$flage -e DAEMON_URL=$DAEMON_URL"
   fi
 fi
}

function get_ip() {
  WANIP=$(curl --silent -m 15 https://api4.my-ip.io/ip | tr -dc '[:alnum:].')
  if [[ "$WANIP" == "" || "$WANIP" = *htmlhead* ]]; then
    WANIP=$(curl --silent -m 15 https://checkip.amazonaws.com | tr -dc '[:alnum:].')
  fi
  if [[ "$WANIP" == "" || "$WANIP" = *htmlhead* ]]; then
    WANIP=$(curl --silent -m 15 https://api.ipify.org | tr -dc '[:alnum:].')
  fi
}

if [[ "$1" == "" ]]; then
echo -e "-----------------------------------------------------------------------"
echo -e "| Blockbook Docker Manager v2.0"
echo -e "-----------------------------------------------------------------------"
echo -e "| Usage:"
echo -e "| status <coin_name>               - show blockbook docker status"
echo -e "| list <url>                       - show coin list"
echo -e "| update                           - update blockbook docker image"
echo -e "| exec <coin_name>                 - login to docker image"
echo -e "| create <coin_name> <-e variable> - create docker blockbook"
echo -e "| <coin_name> <-e variable>        - generate docker run commandline"
echo -e "| clean <coin_name>                - removing blockbook"
echo -e "| softdeploy <coin_name>           - updating image with date"
echo -e "-----------------------------------------------------------------------"
exit
fi

if [[ "$1" == "update" ]]; then
  docker pull xk4milx/blockbook-docker
  exit
fi

if [[ "$1" == "list" ]]; then
  coin_list $2
  exit
fi

if [[ "$1" == "status" ]]; then
  docker inspect fluxosblockbook-${2} | jq .[].State.Health.Log
  exit
fi

if [[ "$1" == "exec" ]]; then
  docker exec -it fluxosblockbook-${2} /bin/bash
  exit
fi

if [[ "$1" == "clean" ]]; then
  echo -e "Stopping docker..."
  docker stop fluxosblockbook-${2}
  docker rm fluxosblockbook-${2}
  echo  -e "Removing data directory...."
  sudo rm -rf /home/$USER/fluxosblockbook_${2}
  exit
fi

setup
if [[ "$1" == "create" || "$1" == "softdeploy" ]]; then
  BLOCKBOOKCONFIG=$(curl -SsL https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/coins/$2.json 2>/dev/null)
else
  BLOCKBOOKCONFIG=$(curl -SsL https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/coins/$1.json 2>/dev/null)
fi
BLOCKBOOKPORT=$(jq -r .ports.blockbook_public 2>/dev/null <<< "$BLOCKBOOKCONFIG")
BLOCKBOOKPOSTINST=$(jq -r .backend.postinst_script_template 2>/dev/null <<< "$BLOCKBOOKCONFIG")

RPC_PORT=$((BLOCKBOOKPORT+1))
OUT_PORT=$((BLOCKBOOKPORT+25005))
if [[ "$BLOCKBOOKPORT" == "" || "$BLOCKBOOKPORT" == "null" ]]; then
  echo -e "Coin config not exists on blockbook github..."
  echo -e ""
  exit
fi

if [[ ! -d /home/$USER/fluxosblockbook_${2} && "$1" == "create" ]]; then
  echo -e "---------------------------------------------------------------------------------------"
  echo -e "| COIN: $2, DIRNAME: fluxosblockbook_${2}"
  echo -e "---------------------------------------------------------------------------------------"
  mkdir /home/$USER/fluxosblockbook_${2}
elif [[ -d /home/$USER/fluxosblockbook_${2} && "$1" == "softdeploy" ]]; then
  echo -e "---------------------------------------------------------------------------------------"
  echo -e "| COIN: $2, DIRNAME: fluxosblockbook_${2}"
  echo -e "---------------------------------------------------------------------------------------"
else
 echo -e "---------------------------------------------------------------------------------------"
 echo -e "| COIN: $1"
 echo -e "---------------------------------------------------------------------------------------"
fi

#if [[ "$BLOCKBOOKPOSTINST" != "" && "$1" != "divi" && "$2" != "divi" ]]; then
  #POSTINST="-e FETCH_FILE=${BLOCKBOOKPOSTINST##*/}"
#fi

get_ip
if [[ "$1" == "create" ]]; then
  EXTRAFLAGS="$3"
  echo -e "| BlockBookURL: http://$WANIP:$OUT_PORT"
  CMD=$(echo "docker run -d --name fluxosblockbook-${2} -e COIN=${2} $BINARY_NAME -e BLOCKBOOK_PORT=${BLOCKBOOKPORT} $flage $POSTINST $EXTRAFLAGS -p ${OUT_PORT}:${BLOCKBOOKPORT} -v /home/$USER/fluxosblockbook_${2}:/root xk4milx/blockbook-docker" | awk '$1=$1')
  echo -e "| $CMD"
  bash -c "$CMD"
  echo -e ""
elif [[ "$1" == "softdeploy" ]]; then
  echo -e "| Stopping continer..."
  echo -e "| Removing image..."
  echo -e "----------------------------------------------------------------------------------------"
  docker stop fluxosblockbook-${2} > /dev/null 2>&1
  docker rm fluxosblockbook-${2} > /dev/null 2>&1
  EXTRAFLAGS="$3"
  echo -e "| BlockBookURL: http://$WANIP:$OUT_PORT"
  CMD=$(echo "docker run -d --name fluxosblockbook-${2} -e COIN=${2} $BINARY_NAME -e BLOCKBOOK_PORT=${BLOCKBOOKPORT} $flage $POSTINST $EXTRAFLAGS -p ${OUT_PORT}:${BLOCKBOOKPORT} -v /home/$USER/fluxosblockbook_${2}:/root xk4milx/blockbook-docker" | awk '$1=$1')
  echo -e "| $CMD"
  bash -c "$CMD"
  echo -e ""
else
  EXTRAFLAGS="$2"
  echo -e "| BlockBookURL: http://$WANIP:$OUT_PORT (EMULATION ONLY)"
  echo -e "| docker run -d --name fluxosblockbook-${1} -e COIN=${1} $BINARY_NAME -e BLOCKBOOK_PORT=${BLOCKBOOKPORT} $flage $POSTINST $EXTRAFLAGS -p ${OUT_PORT}:${BLOCKBOOKPORT} -v /home/$USER/fluxosblockbook_${1}:/root xk4milx/blockbook-docker" | awk '$1=$1'
  echo -e "----------------------------------------------------------------------------------------"
fi
