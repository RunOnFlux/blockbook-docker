# Multicoin Blockbook Explorer

### v3: pinned image
Images are published as `ghcr.io/runonflux/blockbook-docker:<tag>` from `v*` git tags (CI builds and
runs `test/smoke.sh` first). Pin app specs to a tag, never `latest`. Every `v3.*` release also
moves `v3` and `v3.0.0` (the tag the app specs use): Flux nodes check an app's tag every 6 hours
and redeploy it in place with its data kept, while a spec update installs the app afresh
wherever the network places it.

- Blockbook, RocksDB and every coin's configs are built into the image from the
  [ZelCore-io/blockbook](https://github.com/ZelCore-io/blockbook) commit pinned in the `Dockerfile`
  (trezor/blockbook with the Flux/Zelcore explorer UI); nothing is compiled or fetched from GitHub
  at container start. The fork's dashboard feed (`-explorercontenturl`) and Insight API
  (`-insight`) are off unless passed in `BLOCKBOOK_PARAMS`.
  Daemon versions come from that commit's coin configs, with `overrides.json` on top
  (fluxd 9.1.0, zebrad for Zcash, which is copied in from `zfnd/zebra`).
- When the image changes, an existing container re-renders its configs and downloads the new
  daemon; chain data is kept.
- **Peer snapshots** (`snapshot.sh`, `snapshot_server.py`): a synced instance keeps a hard-link
  snapshot of its chain data and serves it on container port 1337 to the other instances of the same
  Flux app. A new or far-behind instance seeds from the best peer instead of syncing from block 0.
  Needs port 1337 mapped in the app spec. `PEER_BOOTSTRAP=0` disables seeding,
  `SNAPSHOT_PEERS="ip:port ..."` seeds from given peers.
- `heal.sh` runs `reconsiderblock` when the daemon has marked the network's chain invalid and
  stopped on its last good block.
- Blockbook stops cleanly (`patches/0002`). It closed its ZMQ socket from another thread while a
  receive was waiting on it, so libzmq aborted the process now and then and the index was left
  marked open. After such a stop, `/api/` showed the last stored height (0 on a new index) until
  the next block.
- `corruption.sh` only wipes a database its own process reports as corrupt or refuses to open
  (another coin, other index settings); `log_clean` only empties named log files (it used to empty
  LevelDB/RocksDB write-ahead logs). It runs every 30 minutes.
- The first sync with several workers is a bulk import: blockbook holds large maps of
  transactions and balances in memory and marks the index inconsistent until it ends. Killed
  before that (out of memory, shared with the daemon), it leaves an index it refuses to open.
  `corruption.sh` rebuilds such an index (from a peer's snapshot if one has it) and
  `/root/blockbook-db.sequential` makes blockbook sync with one worker from then on: slower,
  much less memory, consistent after every block. Blockbook runs with `GOMEMLIMIT` at half the
  container's memory (80% without a local daemon).
- `PRUNE_BACKEND=1` (Bitcoin): the daemon runs without txindex and with manual pruning, and
  `prune.sh` keeps it `PRUNE_KEEP_BLOCKS` (2000) behind blockbook, pausing it at
  `PRUNE_MAX_BLOCKS_GB` (80) of unindexed blocks. Blockbook (`-prunedbackend`, `patches/0001`)
  gets a confirmed transaction from the block its index places it in, and downloads a pruned
  block again from a peer that keeps every block (`getblockfrompeer`), so transactions, address
  and xpub histories, `tx-specific` and blocks come back complete. The first request for an old
  transaction waits for that download (about a second; a history page downloads up to 8 blocks
  at once, and at most 8 run at a time overall); after that it is in the tx cache, which is
  emptied when it passes `TXCACHE_MAX_GB` (20). Without `-extendedindex` Bitcoin needs ~640 GB
  instead of ~1.1 TB plus 886 GB of blocks (2026); as on every other coin without it, a spent
  output gets `spentTxId` only with `?spending=true`. If no peer sends a block, the transaction
  comes from the index: fee and vsize included, scripts and input txids not.
- Zebra releases stop at an end-of-support height about 16 weeks after release: bump
  `ZEBRA_VERSION` in time.

### USAGE
```
bash -i <(curl -s https://raw.githubusercontent.com/RunOnFlux/blockbook-docker/master/blockbook-docker_manager.sh)
```
```
-----------------------------------------------------------------------------
| Blockbook Docker Manager v2.0
-----------------------------------------------------------------------------
| Usage:
| status <coin_name>               - show blockbook docker status
| list <url>                       - show coin list
| update                           - update blockbook docker image
| exec <coin_name>                 - login to docker image
| create <coin_name> <-e variable> - create docker blockbook
| <coin_name> <-e variable>        - generate docker run commandline
| clean <coin_name>                - removing blockbook
| softdeploy <coin_name>           - updating image with date
-----------------------------------------------------------------------------
| FluxOS Blockbook Checker v1.0
-----------------------------------------------------------------------------
| Usage:
| fluxos list                       - list running blockbooks on fluxos
| fluxos <coin_name>                - show information about coin blockbook
-----------------------------------------------------------------------------
```
### Deploy container
```
bash -i <(curl -s https://raw.githubusercontent.com/RunOnFlux/blockbook-docker/master/blockbook-docker_manager.sh) create flux
```

### Maintenance (utils.sh)
```
  -------------------------------------------------------------------------------------
  | Blockbook Utils v2.0
  -------------------------------------------------------------------------------------
  | Usage:
  | blockbook_backup                              - create blockbook database backup
  | blockbook_restore (-archive)/(-remote <url>)  - restore blockbook database
  | blockbook_fix                                 - fix corrupted blockbook database
  | blockbook_clean                               - wipe blockbook database
  | update_daemon <url>                           - update daemon binary
  | backend_backup                                - create backend backup archive
  | backend_restore (-remote <url>)               - restore backend from backup archive
  | backend_clean                                 - wipe backend directory
  | backup_share                                  - share backup archive directory via http
  | backup_archive                                - create backup archive directory
  | log_clean                                     - remove logs
  | archive_clean                                 - remove backup archive directory content 
  | logs <number>                                 - show all logs
  ------------------------------------------------------------------------------------
  () - optional
```

### Environment Variables

To customize some properties of the container, the following environment
variables can be passed via the `-e` parameter (one for each variable).  Value
of this parameter has the format `<VARIABLE_NAME>=<VALUE>`.
 
| Variable       | Description                                  | Required   | Default |
|----------------|----------------------------------------------|------------|---------|
|`COIN`| Name of coin for blockbook | `YES` | `unset` | 
|`DAEMON`| Enable/Disable daemon luncher <br /> DISABLED=0, ENABLED=1  | `NO` | `1` | 
|`BLOCKBOOKGIT_URL`| Custom blockbook github repository URL  | `NO` | `https://github.com/trezor/blockbook.git` | 
|`TAG`| Name of git branch  | `NO` | `master` | 
|`BINARY_NAME`| Name of daemon binary | `NO` | `AUTO` <br />`FROM BLOCKBOOK CONFIG` | 
|`RPC_PORT`| Listen for RPC connections on this TCP port | `YES` | `unset` |
|`RPC_USER`| Usename for RPC connections | `NO` | `user` |
|`RPC_PASS`| Password for RPC connections | `NO` | `pass` |
|`RPC_HOST`| Node hostname for blockbook | `NO` | `localhost` |
|`RPC_URL_PROTOCOL`| Protocol for RPC calls <br /> Info: ETH, ETC using ws | `NO` | `http` |
|`CONFIG_DIR`| Set daemon config dirname when diffrent then .${COIN} | `NO` | `unset` |
|`CONFIG`| Use Config file for daemon <br /> DISABLED=0, ENABLED=1 <br /> Info: DISABLED using cli | `NO` | `1` |
|`EXTRACONFIG`| Additional config option for daemon <br /> Example: "addnode=explorer.flux.zelcore.io\naddnode=explorer.runonflux.io" | `NO` | `unset` |
|`CLIFLAGS`| Config flags for daemon | `YES` <br />when using CLI mode | `unset` |
|`DAEMON_URL`| Download URL for daemon .tar.gz archive | `NO` | `AUTO` <br />`FROM BLOCKBOOK CONFIG` |
|`DAEMON_CONFIG`| Generate daemon config using blockbook template | `NO` | `AUTO` <br />`FROM BLOCKBOOK` |
|`FETCH_FILE`| Name of fetch parms script <br /> Example: "fetch-params.sh" | `NO` | `unset` |
|`LOG_SIZE_LIMIT`| Size limit for log cleaner in MB | `NO` | `40` |
|`BLOCKBOOK_PORT`| Port for blockbook. To get correct port check: <br /> https://github.com/trezor/blockbook/blob/master/docs/ports.md | `YES` | `unset` |
|`BLOCKBOOK_PARAMS`| Blockbook process additional params. This variable can add/overwrite .blockbook.additional_params | `NO` | `unset` |
|`BOOTSTRAP`| Enable daemon bootstrapping <br /> DISABLED=0, ENABLED=1 | `NO` | `0` |
|`B_FILE`| Bootstrap archive file name | `NO` | `daemon_bootstrap.tar.gz` |
|`B_TIMEOUT`| Bootstrap speed test timeout in sec | `NO` | `6` |
|`B_SERVERS_LIST`| Servers list for bootstraping <br /> Example: `'("http://cdn-14.runonflux.io/apps/fluxshare/getfile/" "http://cdn-15.runonflux.io/apps/fluxshare/getfile/")'` | `NO` | `BUILD-IN SERVERS LIST` |

v2.0
