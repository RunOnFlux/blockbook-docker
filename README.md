# Multicoin Blockbook Explorer

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
  | Blockbook Utils v1.0
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
|`BOOTSTRAP`| Enable daemon bootstrapping <br /> DISABLED=0, ENABLED=1 | `NO` | `0` |
|`B_FILE`| Bootstrap archive file name | `NO` | `daemon_bootstrap.tar.gz` |
|`B_TIMEOUT`| Bootstrap speed test timeout in sec | `NO` | `6` |
|`B_SERVERS_LIST`| Servers list for bootstraping <br /> Example: `'("http://cdn-14.runonflux.io/apps/fluxshare/getfile/" "http://cdn-15.runonflux.io/apps/fluxshare/getfile/")'` | `NO` | `BUILD-IN SERVERS LIST` |

v2.0
