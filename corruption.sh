#!/usr/bin/env bash
CONFIG_DIR=${CONFIG_DIR:-$COIN}
CFG_FILE=/root/blockchaincfg.json
#echo -e "| Awaiting for Blockbook build..."
#echo -e "| CONFIG_DIR: $CONFIG_DIR"
while true; do
   if [[ -f $CFG_FILE && -f $HOME/blockbook/blockbook ]]; then
     sleep 240
     break
   fi
   sleep 30
done

echo -e "------------------------------------------ [$(date '+%Y-%m-%d %H:%M:%S')][START]"
echo -e "| Checking blockbook logs...."
if [[ -f /root/blockbook.log ]]; then
  WALs_CHECK=$(grep -ao "rocksDB: Corruption" /root/blockbook.log)
  if [[ "$WALs_CHECK" != "" ]]; then
    echo -e "| RocksDB Corruption detected!..."
    echo -e "| Stopping blockbook service..."
    supervisorctl stop blockbook > /dev/null 2>&1
    echo -e "| Removing old log file..."
    rm -rf /root/blockbook.log
    echo -e "| Repair the database..."
    ./opt/blockbook/blockbook -repair -datadir=/root/blockbook-db
    echo -e "| Starting blockbook service..."
    supervisorctl start blockbook > /dev/null 2>&1
  else
    echo -e "| Corruption NOT detected, all looks fine ;)"
  fi
else
  echo -e "| File does not exists, operation aborted...."
fi
echo -e "----------------------------------------------------------------"
echo -e "| Checking backend logs...."
if [[ -f /root/$CONFIG_DIR/backend/debug.log ]]; then
  corruption=$(egrep -ao "Corrupted|Corruption|ERROR: VerifyDB|printcrashinfo" /root/$CONFIG_DIR/backend/debug.log)
  if [[ "$corruption" != "" ]]; then
    echo -e "| Backend Corruption detected!..."
    echo -e "| Stopping backend service..."
    supervisorctl stop daemon > /dev/null 2>&1
    echo -e "| Removing backend directory contents..."
    rm -rf /root/$CONFIG_DIR/backend/*
    echo -e "| Starting backend service..."
    supervisorctl start daemon > /dev/null 2>&1
  else
    echo -e "| Corruption NOT detected, all looks fine ;)"
  fi
else
  echo -e "| File does not exists, operation aborted...."
fi
echo -e "----------------------------------------------------------------[END]"
