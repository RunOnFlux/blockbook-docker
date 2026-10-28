#!/usr/bin/env bash
# Lays out this coin's config files. Blockbook, RocksDB and the rendered
# configs of every coin are built into the image (see Dockerfile), so this
# takes seconds; there is nothing to compile at run time any more.
#
# When the image changes, the generated files are rendered again from the new
# image: a config left over from an older blockbook or daemon is what kept
# instances on stale daemon versions. Chain data is never touched here.
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
PKG=/opt/blockbook/pkg/$COIN
IMAGE_VERSION="$(cat /opt/blockbook/VERSION) $(md5sum /opt/blockbook/configs/coins/$COIN.json 2>/dev/null | cut -c1-8)"

mkdir -p /run/bb
rm -f /run/bb/prepared
export -p > /run/bb/env.sh

echo -e "| BLOCKBOOK LAUNCHER v3 [$(date '+%Y-%m-%d %H:%M:%S')]"
echo -e "| Image: $IMAGE_VERSION, coin: $COIN"
if [[ -z "$COIN" || ! -f /opt/blockbook/configs/coins/$COIN.json ]]; then
  echo -e "| Unknown coin '$COIN', nothing to start"
  exit 1
fi

PREVIOUS=$(cat /root/.image_version 2>/dev/null)
if [[ -f /root/blockchaincfg.json && "$PREVIOUS" != "$IMAGE_VERSION" ]]; then
  echo -e "| Image changed from [${PREVIOUS:-v2 launcher}], rendering configs again..."
  rm -f /root/blockchaincfg.json /root/CONFIG_CRETED /root/daemon_config.json /root/blockbook.json
  if [[ "$DAEMON_CONFIG" == "AUTO" && -f /root/$CONFIG_DIR/$CONFIG_FILE.conf ]]; then
    mv /root/$CONFIG_DIR/$CONFIG_FILE.conf /root/$CONFIG_DIR/$CONFIG_FILE.conf.old
  fi
fi

if [[ ! -f /root/blockchaincfg.json ]]; then
  echo -e "| Installing blockchaincfg.json"
  cp $PKG/blockchaincfg.json /root/blockchaincfg.json
fi
mkdir -p /root/$CONFIG_DIR /root/blockbook-db
if [[ "$DAEMON_CONFIG" == "AUTO" && -f $PKG/server.conf && ! -f /root/$CONFIG_DIR/$CONFIG_FILE.conf ]]; then
  echo -e "| Installing $CONFIG_FILE.conf"
  cp $PKG/server.conf /root/$CONFIG_DIR/$CONFIG_FILE.conf
  touch /root/$CONFIG_DIR/.conf_fresh
fi
echo "$IMAGE_VERSION" > /root/.image_version

# One file for all jobs, rewritten on every start: appending to a crontab, as
# the previous launcher did, kept old entries forever. flock keeps a slow run
# from stacking up behind the next one.
cat > /etc/cron.d/blockbook <<'EOF'
SHELL=/bin/bash
0 0 */5 * * root . /run/bb/env.sh; /utils.sh log_clean >> /root/maintenance.log 2>&1
5,35 * * * * root . /run/bb/env.sh; flock -n /run/bb/corruption.lock /corruption.sh >> /root/maintenance.log 2>&1
*/30 * * * * root . /run/bb/env.sh; flock -n /run/bb/heal.lock /heal.sh >> /root/maintenance.log 2>&1
*/20 * * * * root . /run/bb/env.sh; flock -n /run/bb/snapshot.lock /snapshot.sh create >> /root/maintenance.log 2>&1
*/5 * * * * root . /run/bb/env.sh; flock -n /run/bb/prune.lock /prune.sh >> /root/maintenance.log 2>&1
47 * * * * root . /run/bb/env.sh; flock -n /run/bb/snapshot.lock /snapshot.sh reseed >> /root/maintenance.log 2>&1
EOF
chmod 644 /etc/cron.d/blockbook
crontab -r 2>/dev/null

touch /run/bb/prepared
echo -e "| Configs ready"
