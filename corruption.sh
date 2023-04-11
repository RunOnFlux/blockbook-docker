#!/usr/bin/env bash
CONFIG_DIR=${CONFIG_DIR:-$COIN}
CFG_FILE=/root/blockchaincfg.json
echo -e "| Awaiting for Blockbook build..."
while true; do
   if [[ -f $CFG_FILE && -f $HOME/blockbook/blockbook ]]; then
     sleep 300
     break
   fi
   sleep 20
done

if [[ -f /root/blockbook.log ]]; then
  echo -e "------------------------------------------ [$(date '+%Y-%m-%d %H:%M:%S')][START]"
  echo -e "| Checking blockbook logs...."
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
  echo -e "----------------------------------------------------------------[END]"
fi

if [[ -f /root/$CONFIG_DIR/backend/$COIN.log ]]; then
  echo -e "------------------------------------------ [$(date '+%Y-%m-%d %H:%M:%S')][START]"
  echo -e "| Checking backend logs...."
  corruption=$(grep -ao "Corrupted block database detected" /root/$CONFIG_DIR/backend/$COIN.log)
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
  echo -e "----------------------------------------------------------------[END]"
fi
