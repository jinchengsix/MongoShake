# error code
ERR_BALANCER_STOP=201
ERR_CHGVXNET_PRECHECK=202
ERR_SCALEIN_SHARD_FORBIDDEN=203
ERR_SERVICE_STOPPED=204
ERR_PORT_NOT_LISTENED=205
ERR_NOTVALID_SHARD_RESTORE=206
ERR_INVALID_PARAMS_MONGOCMD=207
ERR_REPL_NOT_HEALTH=208

# path info
MONGODB_DATA_PATH=/data/mongodb-data
MONGODB_LOG_PATH=/data/mongodb-logs
MONGODB_CONF_PATH=/data/mongodb-conf
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
  if [ $MY_ROLE = "cs_node" ] || [ $MY_ROLE = "mongos_node" ]; then
    echo $(sortHostList ${NODE_LIST[@]})
  else
    echo ${NODE_LIST[@]}
  fi
}

msGetHostDbVersion() {
  local jsstr=$(cat <<EOF
db.version()
EOF
  )
  runMongoCmd "$jsstr" $@
}


getNodesOrder() {
  local tmpstr
  local cnt
  local subcnt
  local tmplist
  local tmpip
  local curmaster
  if [ "$MY_ROLE" = "mongos_node" ]; then
    tmplist=($(sortHostList ${NODE_LIST[@]}))
    cnt=${#tmplist[@]}
    for((i=0;i<$cnt;i++)); do
      tmpstr="$tmpstr,$(getNodeId ${tmplist[i]})"
    done
    tmpstr=${tmpstr:1}
  elif [ "$MY_ROLE" = "cs_node" ]; then
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
    tmpstr="${tmpstr:1},$curmaster"
  else
    cnt=${#INFO_SHARD_GROUP_LIST[@]}
    for((i=1;i<=$cnt;i++)); do
      tmplist=($(eval echo \${INFO_SHARD_${i}_LIST[@]}))
      subcnt=${#tmplist[@]}
      for((j=0;j<$subcnt;j++)); do
        tmpip=$(getIp ${tmplist[j]})
        if msIsHostMaster "$tmpip:$INFO_SHARD_PORT" -H $tmpip -P $INFO_SHARD_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
          curmaster=$(getNodeId ${tmplist[j]})
          continue
        fi
        tmpstr="$tmpstr,$(getNodeId ${tmplist[j]})"
      done
      tmpstr="$tmpstr,$curmaster"
    done
    tmpstr=${tmpstr:1}
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