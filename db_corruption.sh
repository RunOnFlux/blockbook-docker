#!/bin/bash
CFG_FILE=/root/blockchaincfg.json
echo -e "| Awaiting for Blockbook build..."
while true; do
   if [[ -f $CFG_FILE && -f $HOME/blockbook/blockbook ]]; then
     sleep 180
     break
   fi
   sleep 20
done

if [[ -f /root/blockbook.log ]]; then
  echo -e "------------------------------------ [$(date '+%Y-%m-%d %H:%M:%S')][START]"
  echo -e "| Checking blockbook logs...."
  WALs_CHECK=$(grep -o "rocksDB: Corruption" /root/blockbook.log)
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
