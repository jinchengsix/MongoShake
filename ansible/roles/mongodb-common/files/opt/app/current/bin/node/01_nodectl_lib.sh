# error code
ERR_BALANCER_STOP=201
ERR_CHGVXNET_PRECHECK=202
ERR_SCALEIN_SHARD_FORBIDDEN=203
ERR_SERVICE_STOPPED=204
ERR_PORT_NOT_LISTENED=205
ERR_NOTVALID_SHARD_RESTORE=206
ERR_INVALID_PARAMS_MONGOCMD=207
ERR_REPL_NOT_HEALTH=208
ERR_DELETE_NODES_NUM_SHOULD_BE_EVEN=209
ERR_PRIMARY_DELETE_NOT_ALLOWED=210
ERR_HIDDEN_DELETE_NOT_ALLOWED=211

# path info
MONGODB_DATA_PATH=/data/mongodb-data
MONGODB_LOG_PATH=/data/mongodb-logs
MONGODB_CONF_PATH=/data/mongodb-conf
MONGOD_BIN=/opt/mongodb/current/bin/mongod
DB_QC_LOCAL_PASS_FILE=/data/appctl/data/qc_local_pass
HOSTS_INFO_FILE=/data/appctl/data/hosts.info
CONF_INFO_FILE=/data/appctl/data/conf.info
NODE_FIRST_CREATE_FLAG_FILE=/data/appctl/data/node.first.create.flag
REPL_MONITOR_ITEM_FILE=/opt/app/current/bin/node/shard.monitor
HEALTH_CHECK_FLAG_FILE=/data/appctl/data/health.check.flag
BACKUP_FLAG_FILE=/data/appctl/data/backup.flag
CONF_ZABBIX_INFO_FILE=/data/appctl/data/conf.zabbix
ZABBIX_CONF_PATH=/etc/zabbix
ZABBIX_LOG_PATH=/data/zabbix-log

# runMongoCmd
# desc run mongo shell
# $1: script string
# $2-x: option
# -u username, -p passwd
# -P port, -H ip
runMongoCmd() {
  local cmd="/opt/mongodb/current/bin/mongo --quiet"
  local jsstr="$1"
  
  shift
  if [ $(($# % 2)) -ne 0 ]; then log "Invalid runMongoCmd params"; return $ERR_INVALID_PARAMS_MONGOCMD; fi
  while [ $# -gt 0 ]; do
    case $1 in
      "-u") cmd="$cmd --authenticationDatabase admin --username $2";;
      "-p") cmd="$cmd --password $2";;
      "-P") cmd="$cmd --port $2";;
      "-H") cmd="$cmd --host $2";;
    esac
    shift 2
  done

  timeout --preserve-status 5 $cmd --eval "$jsstr"
}

shellStartMongodForAdmin() {
  runuser mongod -g svc -s "/bin/bash" -c "$MONGOD_BIN -f $MONGODB_CONF_PATH/mongo-admin.conf --setParameter disableLogicalSessionCacheRefresh=true"
}

shellStopMongodForAdmin() {
  runuser mongod -g svc -s "/bin/bash" -c "$MONGOD_BIN -f $MONGODB_CONF_PATH/mongo-admin.conf --shutdown"
}

# getSid
# desc: get sid from NODE_LIST item
# $1: a NODE_LIST item (5/192.168.1.2)
# output: sid
getSid() {
  echo $(echo $1 | cut -d'/' -f1)
}

getIp() {
  echo $(echo $1 | cut -d'/' -f2)
}

getNodeId() {
  echo $(echo $1 | cut -d'/' -f3)
}

getGid() {
  echo $(echo $1 | cut -d'/' -f4)
}

getItemFromFile() {
  local res=$(cat $2 | sed '/^'$1'=/!d;s/^'$1'=//')
  echo "$res"
}

# sortHostList
# input
#  $1-n: hosts array
# output
#  sorted array, like 'v1 v2 v3 ...'
sortHostList() {
  echo $@ | tr ' ' '\n' | sort
}

getInitNodeList() {
  echo ${NODE_LIST[@]}
}

clearNodeFirstCreateFlag() {
  if [ -f $NODE_FIRST_CREATE_FLAG_FILE ]; then rm -f $NODE_FIRST_CREATE_FLAG_FILE; fi
}

isNodeFirstCreate() {
  test -f $NODE_FIRST_CREATE_FLAG_FILE
}

enableHealthCheck() {
  touch $HEALTH_CHECK_FLAG_FILE
}

disableHealthCheck() {
  rm -f $HEALTH_CHECK_FLAG_FILE
}

needHealthCheck() {
  test -f $HEALTH_CHECK_FLAG_FILE
}

msGetHostDbVersion() {
  local jsstr=$(cat <<EOF
db.version()
EOF
  )
  runMongoCmd "$jsstr" $@
}

msIsHostMaster() {
  local hostinfo=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status().members)" $@)
  local state=$(echo $tmpstr | jq '.[] | select(.name=="'$hostinfo'") | .stateStr' | sed s/\"//g)
  test "$state" = "PRIMARY"
}

isMeMaster() {
  msIsHostMaster "$MY_IP:$MY_PORT" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
}

isMeNotMaster() {
  ! msIsHostMaster "$MY_IP:$MY_PORT" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
}

msIsHostHidden() {
  local hostinfo=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.conf().members)" $@)
  local pname=$(echo $tmpstr | jq '.[] | select(.hidden==true) | .host' | sed s/\"//g)
  test "$pname" = "$hostinfo"
}

# msIsReplStatusOk
# check if replia set's status is ok
# 1 primary, other's secondary
msIsReplStatusOk() {
  local allcnt=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status())" $@ | jq .members[].stateStr)
  local pcnt=$(echo "$tmpstr" | grep PRIMARY | wc -l)
  local scnt=$(echo "$tmpstr" | grep SECONDARY | wc -l)
  test $pcnt -eq 1
  test $((pcnt+scnt)) -eq $allcnt
}

getNodesOrder() {
  local tmpstr
  local cnt
  local subcnt
  local tmplist
  local tmpip
  local curmaster
  
  tmplist=(${NODE_LIST[@]})
  cnt=${#tmplist[@]}
  for((i=0;i<$cnt;i++)); do
    tmpip=$(getIp ${tmplist[i]})
    if msIsHostMaster "$tmpip:$MY_PORT" -H $tmpip -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
      curmaster=$(getNodeId ${tmplist[i]})
      continue
    fi
    tmpstr="$tmpstr,$(getNodeId ${tmplist[i]})"
  done
  if [ -z "$tmpstr" ]; then
    tmpstr="$curmaster"
  else
    tmpstr="${tmpstr:1},$curmaster"
  fi
  
  log "$tmpstr"
  echo $tmpstr
}

# sort nodes for changing configue
# secodary node first, primary node last
getRollingList() {
  local cnt=${#NODE_LIST[@]}
  local tmpstr
  local master
  local ip
  for((i=0;i<$cnt;i++)); do
    ip=$(getIp ${NODE_LIST[i]})
    if msIsHostMaster "$ip:$MY_PORT" -H $ip -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
      master=${NODE_LIST[i]}
      continue
    fi
    tmpstr="$tmpstr ${NODE_LIST[i]}"
  done
  tmpstr="$tmpstr $master"
  echo $tmpstr
}

getOperationProfilingModeCode() {
  local res
  case $1 in
    "off") res=0;;
    "slowOp") res=1;;
    "all") res=2;;
  esac
  echo $res
}

msGetServerStatus() {
  local tmpstr=$(runMongoCmd "JSON.stringify(db.serverStatus())" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  echo "$tmpstr"
}

createMongoConf() {
  local replication_replSetName
  local storage_engine
  local net_port
  local setParameter_cursorTimeoutMillis
  local operationProfiling_mode
  local operationProfiling_slowOpThresholdMs
  local replication_enableMajorityReadConcern
  local read_concern
  
  net_port=$(getItemFromFile net_port $CONF_INFO_FILE)
  setParameter_cursorTimeoutMillis=$(getItemFromFile setParameter_cursorTimeoutMillis $CONF_INFO_FILE)
  replication_replSetName=$(getItemFromFile replication_replSetName $CONF_INFO_FILE)
  storage_engine=$(getItemFromFile storage_engine $CONF_INFO_FILE)
  operationProfiling_mode=$(getItemFromFile operationProfiling_mode $CONF_INFO_FILE)
  operationProfiling_slowOpThresholdMs=$(getItemFromFile operationProfiling_slowOpThresholdMs $CONF_INFO_FILE)
  replication_enableMajorityReadConcern=$(getItemFromFile replication_enableMajorityReadConcern $CONF_INFO_FILE)
  replication_oplogSizeMB=$(getItemFromFile replication_oplogSizeMB $CONF_INFO_FILE)
  read_concern="enableMajorityReadConcern: $replication_enableMajorityReadConcern"
  
  cat > $MONGODB_CONF_PATH/mongo.conf <<MONGO_CONF
systemLog:
  destination: file
  path: $MONGODB_LOG_PATH/mongo.log
  logAppend: true
  logRotate: reopen
net:
  port: $net_port
  bindIp: 0.0.0.0
security:
  keyFile: $MONGODB_CONF_PATH/repl.key
  authorization: enabled
storage:
  dbPath: $MONGODB_DATA_PATH
  journal:
    enabled: true
  engine: $storage_engine
operationProfiling:
  mode: $operationProfiling_mode
  slowOpThresholdMs: $operationProfiling_slowOpThresholdMs
replication:
  oplogSizeMB: $replication_oplogSizeMB
  replSetName: $replication_replSetName
  $read_concern
setParameter:
  cursorTimeoutMillis: $setParameter_cursorTimeoutMillis
MONGO_CONF

    cat > $MONGODB_CONF_PATH/mongo-admin.conf <<MONGO_CONF
systemLog:
  destination: syslog
net:
  port: $NET_MAINTAIN_PORT
  bindIp: 0.0.0.0
storage:
  dbPath: $MONGODB_DATA_PATH
  journal:
    enabled: true
  engine: $storage_engine
processManagement:
  fork: true
MONGO_CONF
}

createZabbixConf() {
  local zServer=$(getItemFromFile Server $CONF_ZABBIX_INFO_FILE)
  local zListenPort=$(getItemFromFile ListenPort $CONF_ZABBIX_INFO_FILE)
  cat > $ZABBIX_CONF_PATH/zabbix_agent2.conf <<ZABBIX_CONF
PidFile=/var/run/zabbix/zabbix_agent2.pid
LogFile=/data/zabbix-log/zabbix_agent2.log
LogFileSize=50
Server=$zServer
#ServerActive=127.0.0.1
ListenPort=$zListenPort
Include=/etc/zabbix/zabbix_agent2.d/*.conf
UnsafeUserParameters=1
ZABBIX_CONF
}