# Multicoin Blockbook Explorer

### Pull latest image
```shell script
$ docker pull runonflux/blockbook-docker
```
### Deploy container
```shell script
docker run -d --name fluxblockbook-flux -e COIN=flux -e BOOTSTRAP=1 -e EXTRACONFIG="addnode=explorer.zelcash.online\naddnode=explorer.runonflux.io\naddnode=blockbook.runonflux.io\naddnode=explorer.flux.zelcore.io" -e BLOCKBOOK_PORT=9158 -e -p 7799:9158 -v /<local_path>:/root runonflux/blockbook-docker
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

v1.0.1
