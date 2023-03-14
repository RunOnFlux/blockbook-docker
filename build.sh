#!/usr/bin/env bash
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
BLOCKBOOKGIT_URL=${BLOCKBOOKGIT_URL:-https://github.com/trezor/blockbook.git}
re="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
if [[ $BLOCKBOOKGIT_URL =~ $re ]]; then
  GIT_USER=${BASH_REMATCH[4]}
  REPO=$(cut -d "." -f 1 <<< ${BASH_REMATCH[5]})
fi
VERSION=$(curl -ssL https://raw.githubusercontent.com/$GIT_USER/$REPO/$TAG/configs/environ.json | jq -r .version)
start_build=`date +%s`

function rocksdb_install(){
  if [[ -d $HOME/rocksdb ]]; then
    return
  fi
  echo -e "| Installing RocksDB [$ROCKSDB_VERSION]..."
  echo -e "| PATH: $HOME/rocksdb"
  cd $HOME && git clone -b $ROCKSDB_VERSION --depth 1 https://github.com/facebook/rocksdb.git > /dev/null 2>&1
  cd $HOME/rocksdb && CFLAGS=-fPIC CXXFLAGS='-fPIC -Wno-error=deprecated-copy -Wno-error=pessimizing-move -Wno-error=class-memaccess' PORTABLE=1 make -j 4 release > /dev/null 2>&1
  if [[ -f $HOME/rocksdb/librocksdb.a ]]; then
   echo -e "| RocksDB BUILD [OK]..."
  else
   echo -e "| RocksDB BUILD [FAILED]..."
   rm -rf $HOME/rocksdb
  fi 
}

function blockbook_install() {
  if [[ -d $HOME/blockbook ]]; then
   return
  fi
  echo -e "| Installing Blockbook [v$VERSION]..."
  echo -e "| GITHUB URL: $BLOCKBOOKGIT_URL, BRANCH: $TAG"
  echo -e "| PATH: $HOME/blockbook" 
  cd $HOME && git clone $BLOCKBOOKGIT_URL
  cd $HOME/blockbook 
  git checkout "$TAG" > /dev/null 2>&1
  go mod download 
  BUILDTIME=$(date --iso-8601=seconds)
  GITCOMMIT=$(git describe --always --dirty)
  LDFLAGS="-X github.com/trezor/blockbook/common.version=${VERSION} -X github.com/trezor/blockbook/common.gitcommit=${GITCOMMIT} -X github.com/trezor/blockbook/common.buildtime=${BUILDTIME}"
  go build -tags rocksdb_6_16 -ldflags="-s -w ${LDFLAGS}"
}

function setup() {
  echo -e "| BLOCKBOOK LUNCHER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "-----------------------------------------------------"
  if [[ -d $HOME/blockbook ]]; then
    echo -e "| Installed GOLANG [$GOLANG_VERSION]..."
    echo -e "| PATH: $HOME/go"
    echo -e "| Installed RocksDB [$ROCKSDB_VERSION]..."
    echo -e "| PATH: $HOME/rocksdb"
    echo -e "| Installed Blockbook [v$VERSION]..."
    echo -e "| PATH: $HOME/blockbook"
  else
    echo -e "| Installed GOLANG [$GOLANG_VERSION]..."
    echo -e "| PATH: $HOME/go"
    x=1
    while [ $x -le 4 ]
    do
      rocksdb_install
      if [[ ! -f $HOME/rocksdb/librocksdb.a ]]; then
        continue
      fi
      blockbook_install
      x=$(( $x + 1 ))
      if [[ -f $HOME/blockbook/blockbook ]]; then
        echo -e "| Blockbook BUILD [OK]..."
        break
      else
        echo -e "| Blockbook BUILD [FAILED]..."
        rm -rf $HOME/blockbook
        rm -rf $HOME/rocksdb
      fi 
      echo -e "| Duration: $((($(date +%s)-$start_build)/60)) min. $((($(date +%s)-$start_build) % 60)) sec."
    done
  fi
  
  if [[ ! -f $HOME/blockbook/blockbook ]]; then
    echo -e "-----------------------------------------------------"
    exit
  fi
}
##### Install Process
setup
##########################
if [[ ! -f /root/blockchaincfg.json ]]; then
  if [[ ! -d /root/$CONFIG_DIR ]]; then
    echo -e "| Creating config directory..."
    mkdir -p /root/$CONFIG_DIR
  fi
  cd $HOME/blockbook 
  echo -e "| Generating config files for $COIN"
  go run build/templates/generate.go $COIN > /dev/null  
  if [[ -f $HOME/blockbook/build/pkg-defs/blockbook/blockchaincfg.json ]]; then
    echo -e "| Moving blockchaincfg.json"
    mv $HOME/blockbook/build/pkg-defs/blockbook/blockchaincfg.json /root
  fi
  if [[ "$DAEMON_CONFIG" == "AUTO" ]]; then
    if [[ -f $HOME/blockbook/build/pkg-defs/backend/server.conf ]]; then
      echo -e "| Moving $CONFIG_FILE.conf"
      mv $HOME/blockbook/build/pkg-defs/backend/server.conf /root/$CONFIG_DIR/$CONFIG_FILE.conf
    fi
  fi
  rm -rf $HOME/blockbook/build/pkg-defs
  echo -e "-----------------------------------------------------"
else
  echo -e "-----------------------------------------------------"
fi
echo -e "| CRON JOB CHECKING..."
[ -f /var/spool/cron/crontabs/root ] && crontab_check=$(cat /var/spool/cron/crontabs/root| grep -o utils | wc -l) || crontab_check=0
if [[ "$crontab_check" == "0" ]]; then
  echo -e "| ADDED CRONE JOB FOR LOG CLEANER..."
  echo -e "-----------------------------------------------------"
  (crontab -l -u root 2>/dev/null; echo "0 0 1-30/5 * *  /bin/bash /utils.sh log_clean > /tmp/clean_output.log 2>&1") | crontab -
else
  echo -e "| CRONE JOB ALREADY EXIST..."
  echo -e "-----------------------------------------------------"
fi
