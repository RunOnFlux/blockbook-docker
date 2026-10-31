#!/usr/bin/env bash
# Frees a daemon that has marked the real chain invalid.
#
# A node that ran an older release across a consensus change (or hit a bug)
# flags the next block BLOCK_FAILED_VALID and stays on its last good block for
# good: the flag is persisted, so upgrading the binary does not clear it. Seen
# on blockbookflux: seven instances stuck at 2263328 for months while their
# getchaintips listed the network's chain as "invalid".
#
# reconsiderblock on that tip clears the flag on it and its ancestors and the
# node revalidates with the current binary. If the block really is invalid it
# is simply marked again, so trying once a day is harmless.
CONFIG_FILE=${CONFIG_FILE:-$COIN}
CONFIG_DIR=${CONFIG_DIR:-$COIN}
STATE=/root/heal_state.json
LOG=/root/heal_events.log
MIN_LEAD=${HEAL_MIN_LEAD:-12}

[[ "$DAEMON" == "1" && -f /run/bb/bootstrapped ]] || exit 0
CLI_NAME=${CLI_NAME:-$(jq -r '.cli_name // empty' /root/daemon_config.json 2>/dev/null)}
[[ -n "$CLI_NAME" ]] && command -v "$CLI_NAME" > /dev/null || exit 0

# Credentials from blockchaincfg.json: several backend configs only carry a
# hashed rpcauth line, which a CLI cannot log in with.
function cli() {
  local user pass
  user=$(jq -r '.rpc_user // empty' /root/blockchaincfg.json)
  pass=$(jq -r '.rpc_pass // empty' /root/blockchaincfg.json)
  if [[ -f /root/$CONFIG_DIR/$CONFIG_FILE.conf ]]; then
    timeout 120 "$CLI_NAME" -conf="/root/$CONFIG_DIR/$CONFIG_FILE.conf" -rpcuser="$user" -rpcpassword="$pass" "$@"
  else
    timeout 120 "$CLI_NAME" -rpcuser="${user:-$RPC_USER}" -rpcpassword="${pass:-$RPC_PASS}" "$@"
  fi
}

TIPS=$(cli getchaintips 2>/dev/null) || exit 0
ACTIVE=$(jq -r '[.[] | select(.status=="active")][0].height // 0' <<< "$TIPS")
CANDIDATE=$(jq -r --argjson a "$ACTIVE" --argjson lead "$MIN_LEAD" \
  '[.[] | select(.status=="invalid" and .height > ($a + $lead))] | max_by(.height) | .hash // empty' <<< "$TIPS")
[[ -n "$CANDIDATE" ]] || exit 0

[[ -f $STATE ]] || echo '{}' > $STATE
LAST=$(jq -r --arg h "$CANDIDATE" '.[$h] // 0' $STATE)
NOW=$(date +%s)
if (( NOW - LAST < 86400 )); then
  exit 0
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] active tip at $ACTIVE, invalid tip $CANDIDATE is ahead: reconsiderblock" >> $LOG
OUT=$(cli reconsiderblock "$CANDIDATE" 2>&1)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] reconsiderblock -> ${OUT:-ok}, height now $(cli getblockcount 2>/dev/null)" >> $LOG
echo "$(jq --arg h "$CANDIDATE" --argjson t "$NOW" '.[$h]=$t' $STATE)" > $STATE
