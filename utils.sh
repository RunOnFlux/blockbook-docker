#!/usr/bin/env bash
CONFIG_DIR=${CONFIG_DIR:-$COIN}

function tar_file_pack() {
	echo -e "| Creating archive file..."
	tar -czf - $1 | (pv -p --timer --rate --bytes > $2) 2>&1
}

function tar_file_unpack()
{
    echo -e "| Unpacking archive file..."
    pv $1 | tar -zx -C $2
}

function extract_daemon() {
  if [[ ! -d /tmp/backend ]]; then
    echo -e "| Creating directory..."
    mkdir -p /tmp/backend
  fi
  echo -e "| Unpacking daemon bin archive file..."
  strip_lvl=$(bsdtar -tvf ${DAEMON_URL##*/} | grep ${BINARY_NAME}$ | awk '{ printf "%s\n", $9 }' | awk -F\/ '{print NF-1}')
  bsdtar --exclude="share" --exclude="lib" --exclude="include" -C backend --strip $strip_lvl -xf ${DAEMON_URL##*/} > /dev/null 2>&1 || return 1
  return 0
}

function auto_restore(){
  if [[ "$1" == "blockbook" ]]; then
    URL=$(curl -sSL -m 10 https://fluxnodeservice.com/blockbook/index.json | jq -r '.blockbook_backup[].url' | grep "$COIN-db")
  fi
  if [[ "$1" == "backend" ]]; then
    URL=$(curl -sSL -m 10 https://fluxnodeservice.com/blockbook/index.json | jq -r '.backend_backup[].url' | grep "$COIN-")
  fi
  if [[ "$URL" == "" ]]; then
    echo -e "| Backup archive not found, operation aborted..."
    echo -e "--------------------------------------------------"
    exit
  fi
}

if [[ "$1" == "" ]]; then
  echo -e "---------------------------------------------------------------------------------------------"
  echo -e "| Blockbook Utils v1.0"
  echo -e "---------------------------------------------------------------------------------------------"
  echo -e "| Usage:"
  echo -e "| blockbook_backup                              - create blockbook database backup"
  echo -e "| blockbook_restore (-archive)/(-remote <url>)  - restore blockbook database"
  #echo -e "| blockbook_gzip                                - gzip blockbook database"
  echo -e "| blockbook_fix                                 - fix corrupted blockbook database"
  echo -e "| blockbook_clean                               - remove blockbook database"
  echo -e "| update_daemon <url>                           - update daemon binary"
  echo -e "| backend_backup                                - create backend backup archive"
  echo -e "| backend_restore (-remote <url>)               - restore backend from backup archive"
  echo -e "| backend_clean                                 - remove backend directory content"
  echo -e "| backup_share                                  - share backup archive directory via http"
  echo -e "| backup_archive                                - create backup archive directory"
  echo -e "| archive_clean                                 - remove backup archive directory content"
  echo -e "| log_clean                                     - remove logs"
  echo -e "| logs <number>                                 - show all logs"
  echo -e "-------------------------------------------------------------------------------------------"
  exit
fi

if [[ "$1" == "logs" ]]; then
  if [[ "$2" == "" ]]; then
    LINE=50
  else
    LINE=$2
  fi

  echo -e "-----------------------------------------------------------------------------------------------"
  echo -e "| BLOCKBOOK LOGS CHECKER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "-----------------------------------------------------------------------------------------------"
  echo -e "| CHECKING BUILD LOGS..."
  echo -e "----------------------------------------------------------------------------------[START BUILD]"
  supervisorctl tail build | tail -n${LINE}
  echo -e "------------------------------------------------------------------------------------[END BUILD]"
  echo -e "| CHECKING DAEMON LOGS..."
  echo -e "---------------------------------------------------------------------------------[START DAEMON]"
  supervisorctl tail daemon | tail -n${LINE}
  echo -e "-----------------------------------------------------------------------------------[END DAEMON]"
  echo -e "| CHECKING BLOCKBOOK LOGS..."
  echo -e "------------------------------------------------------------------------------[START BLOCKBOOK]"
  supervisorctl tail blockbook | tail -n${LINE}
  echo -e "--------------------------------------------------------------------------------[END BLOCKBOOK]"
  echo -e "| CHECKING DB CORRUPTION LOGS..."
  echo -e "------------------------------------------------------------------------------[START CORRUPTION]"
  supervisorctl tail db_corruption | tail -n${LINE}
  echo -e "--------------------------------------------------------------------------------[END CORRUPTION]"
  
  if [[ -f /root/$CONFIG_DIR/backend/debug.log ]]; then
    echo -e "| File: /root/$CONFIG_DIR/backend/debug.log"
    echo -e "-----------------------------------------------------------------------------------------------"
    cat /root/$CONFIG_DIR/backend/debug.log | tail -n${LINE}
    echo -e "------------------------------------------------------------------------------------------[END]"
  fi
  if [[ -f /root/blockbook.log ]]; then
    echo -e "| File: /root/blockbook.log"
    echo -e "-----------------------------------------------------------------------------------------------"
    cat /root/blockbook.log | tail -n${LINE}
    echo -e "------------------------------------------------------------------------------------------[END]"
  fi
  if [[ -f /root/$CONFIG_DIR/backend/$COIN.log ]]; then
    echo -e "| File: /root/$CONFIG_DIR/backend/$COIN.log"
    echo -e "-----------------------------------------------------------------------------------------------"
    cat /root/$CONFIG_DIR/backend/$COIN.log | tail -n${LINE}
    echo -e "------------------------------------------------------------------------------------------[END]"
  fi
  echo -e "| HEALTH CHECKING ..."
  echo -e "----------------------------------------------------------------------------------------------"
  echo -n "| "
  ./check-health.sh
  echo -e "----------------------------------------------------------------------------------------------"
  exit
fi

#if [[ "$1" == "blockbook_gzip" ]]; then
  #echo -e "| BLOCKBOOK DB GZIP v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  #echo -e "--------------------------------------------------"
  #echo -e "| Checking backup directory..."
  #if [[ -d /root/blockbook_backup/rocksdb.bk ]]; then
    #cd /root
    #tar_file_pack "blockbook_backup" "/root/blockbook-$COIN-db-backup.tar.gz"
    #echo -e "| Backup archive created, path: /root/blockbook-$COIN-db-backup.tar.gz"
  #else
    #echo -e "| Backup directory not exist, operation aborted..."
  #fi
  #echo -e "--------------------------------------------------"
  #exit
#fi

if [[ "$1" == "blockbook_fix" ]]; then
  echo -e "| BLOCKBOOK DB FIXER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  echo -e "| Stopping blockbook service..."
  supervisorctl stop blockbook > /dev/null 2>&1
  echo -e "| Repair the database..."
  ./opt/blockbook/blockbook -repair -datadir=/root/blockbook-db
  echo -e "| Starting blockbook service..."
  supervisorctl start blockbook > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "blockbook_backup" ]]; then
  echo -e "| BLOCKBOOK DB BACKUP v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  echo -e "| Stopping blockbook service..."
  supervisorctl stop blockbook > /dev/null 2>&1
  echo -e "| Backuping the database..."
  if [[ -d /root/blockbook_backup ]]; then
    rm -rf /root/blockbook_backup/* > /dev/null 2>&1
  else
    mkdir -p /root/blockbook_backup
  fi
  cd /
  ./opt/rocksdb/ldb --db=/root/blockbook-db backup --backup_dir=/root/blockbook_backup/rocksdb.bk
  echo -e "| Checking backup directory..."
  if [[ -d /root/blockbook_backup/rocksdb.bk ]]; then
    cd /root
    tar_file_pack "blockbook_backup" "/root/blockbook-$COIN-db-backup.tar.gz"
    echo -e "| Backup archive created, path: /root/blockbook-$COIN-db-backup.tar.gz"
  else
    echo -e "| Backup failed..."
  fi
  rm -rf /root/blockbook_backup/rocksdb.bk
  echo -e "| Starting blockbook service..."
  supervisorctl start blockbook > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "blockbook_restore" ]]; then
  echo -e "| BLOCKBOOK DB RESTORE v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  echo -e "| Stopping blockbook service..."
  supervisorctl stop blockbook > /dev/null 2>&1
  
  if [[ "$2" == "-archive" ]]; then
    if [[ -f /root/blockbook-$COIN-db-backup.tar.gz ]]; then
      rm -rf /root/blockbook_backup
      tar_file_unpack "/root/blockbook-$COIN-db-backup.tar.gz" "/root"
    fi
  fi
  
  if [[ "$2" == "-remote" && "$3" != "" ]]; then
   cd /root
   if [[ -f /root/blockbook-$COIN-db-backup.tar.gz ]]; then
     rm -rf /root/blockbook-$COIN-db-backup.tar.gz
   fi
   
   if [[ "$3" == "auto" ]]; then
     auto_restore "blockbook"
   else
     URL=$3
   fi
  
   echo -e "| Downloading file: $URL"
   wget -q --show-progress -c -t 5 $URL -O blockbook-$COIN-db-backup.tar.gz
   if [[ $? -ne 0 ]]; then
     echo -e "| Download archive backup failed, operation aborted..."
     rm -rf /root/backend-$COIN-backup.tar.gz
     echo -e "--------------------------------------------------"
     exit
    fi
    rm -rf /root/blockbook_backup
    tar_file_unpack "/root/blockbook-$COIN-db-backup.tar.gz" "/root"
    rm -rf /root/blockbook-$COIN-db-backup.tar.gz
  fi

  if [[ ! -d /root/blockbook_backup/rocksdb.bk ]]; then
    echo -e "| Backup directory not exist, operation aborted..."
    echo -e "--------------------------------------------------"
    exit
  fi
  echo -e "| Restoring the database..."
  cd /
  ./opt/rocksdb/ldb --db=/root/blockbook-db restore --backup_dir=/root/blockbook_backup/rocksdb.bk
  echo -e "| Removing blockbook_backup directory..."
  rm -rf /root/blockbook_backup
  echo -e "| Starting blockbook service..."
  supervisorctl start blockbook > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "blockbook_clean" ]]; then
  echo -e "| BLOCKBOOK DB CLEANER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  echo -e "| Stopping blockbook service..."
  supervisorctl stop blockbook > /dev/null 2>&1
  echo -e "| Removing blockbook-db..."
  rm -rf /blockbook-db/*
  echo -e "| Starting blockbook service..."
  supervisorctl start blockbook > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "update_daemon" ]]; then
  echo -e "| DAEMON UPDATE v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  DAEMON_URL=$2
  if [[ "$DAEMON_URL" == "" ]]; then
    echo -e "| Missing binary url..."
    echo -e "--------------------------------------------------"
    exit
  fi
  echo "$(jq -r --arg key "daemon_url" --arg value "$DAEMON_URL" '.[$key]=$value' /root/daemon_config.json)" > /root/daemon_config.json
  echo -e "| Stopping daemon service..."
  supervisorctl stop daemon > /dev/null 2>&1
  if [[ "$BINARY_NAME" == "" ]]; then
    BINARY_NAME=$(jq -r .binary_name /root/daemon_config.json)
  fi
  echo -e "| Removing daemon binary..."
  rm -rf /usr/local/bin/$BINARY_NAME
  echo -e "| BINARY URL: $DAEMON_URL"
  cd /tmp
  wget -q --show-progress -c -t 5 $DAEMON_URL
  extract_daemon
  echo -e "| Installing daemon..."
  install -m 0755 -o root -g root -t /usr/local/bin backend/*
  rm -rf /tmp/*
  echo -e "| Starting daemon service..."
  supervisorctl start daemon > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "backend_backup" ]]; then
  echo -e "| BLOCKBOOK BACKEND BACKUP v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  echo -e "| Checking backup file..."
  if [[ -f /root/backend-$COIN-backup.tar.gz ]]; then
    rm -rf  /root/backend-$COIN-backup.tar.gz
  fi
  echo -e "| Stopping daemon service..."
  supervisorctl stop daemon > /dev/null 2>&1
  cd /root/$CONFIG_DIR
  tar_file_pack "backend" "/root/backend-$COIN-backup.tar.gz"
  if [[ -f /root/backend-$COIN-backup.tar.gz ]]; then
   echo -e "| Backup archive created, path: /root/backend-$COIN-backup.tar.gz"
  else
   echo -e "| Backup not created, operation failed..."
  fi
  echo -e "| Starting daemon service..."
  supervisorctl start daemon > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "backend_restore" ]]; then
  echo -e "| BLOCKBOOK BACKEND RESTORE v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  
  if [[ "$2" == "-remote" && "$3" != "" ]]; then
   if [[ -f /root/backend-$COIN-backup.tar.gz ]]; then
     rm -rf /root/backend-$COIN-backup.tar.gz
   fi
   cd /root
   
   if [[ "$3" == "auto" ]]; then
     auto_restore "backend"
   else
     URL=$3
   fi
   
   echo -e "| Downloading file: $URL"
   wget -q --show-progress -c -t 5 $URL -O backend-$COIN-backup.tar.gz
   if [[ $? -ne 0 ]]; then
    echo -e "| Download archive backup failed, operation aborted..."
    rm -rf /root/backend-$COIN-backup.tar.gz
    echo -e "--------------------------------------------------"
    exit
   fi
  else
   echo -e "| Checking backup file..."
   if [[ ! -f /root/backend-$COIN-backup.tar.gz ]]; then
     echo -e "| Backup file not exist, operation aborted..."
     echo -e "--------------------------------------------------"
     exit
   fi
  fi
  cd /root/$CONFIG_DIR
  echo -e "| Stopping daemon service..."
  supervisorctl stop daemon > /dev/null 2>&1
  echo -e "| Cleaning backend datadir..."
  rm -rf /root/$CONFIG_DIR/backend
  tar_file_unpack "/root/backend-$COIN-backup.tar.gz" "/root/$CONFIG_DIR"
  if [[ -d /root/$CONFIG_DIR/backend ]]; then
   echo -e "| Restore finished, source: /root/backend-$COIN-backup.tar.gz"
  else
   echo -e "| Restore failed..."
   mkdir -p /root/$CONFIG_DIR/backend
  fi
  rm -rf /root/backend-$COIN-backup.tar.gz
  echo -e "| Starting daemon service..."
  supervisorctl start daemon > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "backup_archive" ]]; then
  echo -e "| BLOCKBOOK BACKUP ARCHIVE v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  timestamp=$(date +%s)
  mkdir -p /root/backup_archive > /dev/null 2>&1
  if [[ -f /root/backend-$COIN-backup.tar.gz ]]; then
    echo -e "| File backend-$COIN-backup.tar.gz moved to /root/backup_archive"
    mv /root/backend-$COIN-backup.tar.gz /root/backup_archive/backend-$COIN-backup-${timestamp}.tar.gz
  fi
  if [[ -f /root/blockbook-$COIN-db-backup.tar.gz ]]; then
    echo -e "| File blockbook-$COIN-db-backup.tar.gz moved to /root/backup_archive"
    mv /root/blockbook-$COIN-db-backup.tar.gz /root/backup_archive/blockbook-$COIN-db-backup-${timestamp}.tar.gz
  fi
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "backup_share" ]]; then
  echo -e "| BLOCKBOOK BACKUP HTTP SERVER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  if [[ -d /root/backup_archive ]]; then
    echo -n "| "
    cd /root/backup_archive
    python3 -m http.server 1337
  else
    echo -e "Backup directory not exist, operation aborted..."
  fi
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "archive_clean" ]]; then
  echo -e "| BLOCKBOOK BACKUP ARCHIVE CLEANER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "------------------------------------------------------------"
  echo -e "| Checking directory..."
  if [[ -d /root/backup_archive ]]; then
    cd /root/backup_archive
    FILE_LIST=($(ls -p /root/backup_archive))
    LENGTH=${#FILE_LIST[@]}
    for (( j=0; j<${LENGTH}; j++ ));
    do
      echo -e "| File: /root/backup_archive/${FILE_LIST[j]} was removed!"
      rm -rf ./${FILE_LIST[j]}
    done
  echo -e "| Removed $LENGTH files"
  else
     echo -e "| Backup archive directory not exist, operation aborted!"
  fi
  echo -e "------------------------------------------------------------"
  exit
fi

if [[ "$1" == "backend_clean" ]]; then
  echo -e "| BACKEND CLEANER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  echo -e "| Stopping daemon service..."
  supervisorctl stop daemon > /dev/null 2>&1
  echo -e "| Cleaning backend datadir..."
  rm -rf /root/$CONFIG_DIR/backend/*
  echo -e "| Starting daemon service..."
  supervisorctl start daemon > /dev/null 2>&1
  echo -e "--------------------------------------------------"
  exit
fi

if [[ "$1" == "log_clean" ]]; then
  CLEAN=0
  echo -e "| LOG CLEANER v2.0 [$(date '+%Y-%m-%d %H:%M:%S')]"
  echo -e "--------------------------------------------------"
  LOG_SIZE_LIMIT=${LOG_SIZE_LIMIT:-20}
  LOG_LIST=($(find /root -type f \( -name "$COIN*.log" -o -name "debug.log" -o -name "blockbook.log*" -o -name "*.log" \)))
  LENGTH=${#LOG_LIST[@]}
  for (( j=0; j<${LENGTH}; j++ ));
  do
   LOG_PATH="${LOG_LIST[$j]}"
   SIZE=$(ls -l --b=M  $LOG_PATH | cut -d " " -f5)
   #echo -e "| File: ${LOG_PATH} SIZE: ${SIZE}"
   if [[ $(egrep -o '[0-9]+' <<< $SIZE) -gt $LOG_SIZE_LIMIT ]]; then
     echo -e "| FOUND: ${LOG_PATH} SIZE: ${SIZE}"
     LOG_FILE=${LOG_PATH##*/}
     echo -e "| File ${LOG_FILE} reached ${LOG_SIZE_LIMIT}M limit, file was cleaned!"
     if [[ -f $LOG_PATH ]]; then
       echo "" > $LOG_PATH > /dev/null 2>&1
     fi
     CLEAN=1
   fi
  done
  if [[ "$CLEAN" == "0" ]]; then
   echo -e "| All logs belown ${LOG_SIZE_LIMIT}M limit..."
  fi
  echo -e "--------------------------------------------------"
fi
