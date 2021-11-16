backup() {
  log "star backup"
  # set backup flag
  touch $BACKUP_FLAG_FILE
}

cleanup() {
  log "start cleanup"
  # reset backup flag
  rm -rf $BACKUP_FLAG_FILE
}

restore() {
  log "start restore"
  preRestore
  doWhenRestoreRepl
  postRestore
}

preRestore() {
  log "restore step 1"
  disableHealthCheck
  log "restore step 2"
  systemctl stop mongod.service || :
  # repl.key
  echo "$GLOBAL_UUID" | base64 > "$MONGODB_CONF_PATH/repl.key"
  chown mongod:svc $MONGODB_CONF_PATH/repl.key
  chmod 0400 $MONGODB_CONF_PATH/repl.key
  #qc_local_pass
  encrypted=$(echo -n ${GLOBAL_UUID}${CLUSTER_ID} | sha256sum | base64)
  echo ${encrypted:16:16} > $DB_QC_LOCAL_PASS_FILE
}

doWhenRestoreRepl() {
  log "restore step 3"
  # sync from host.info.new & recreate mongo conf
  updateHostsInfo
  log "restore step 4"
  updateMongoConf
  log "restore step 5"

  local cnt=${#NODE_LIST[@]}
  log "restore step 6 , cnt :$cnt , nodeList: $NODE_LIST"
  local ip=$(getIp ${NODE_LIST[0]})
  log "restore step 7 , ip: $ip"
  if [ ! $ip = "$MY_IP" ]; then
  log "restore step 8"
    rm -rf $MONGODB_DATA_PATH/*
    _start
    return 0
  fi

  # start mongod in admin mode
  shellStartMongodForAdmin

  local jsstr
  retry 60 3 0 msGetHostDbVersion -P $NET_MAINTAIN_PORT

  # change qc_master and zabbix's passowrd
  local newpass=$(cat $DB_QC_LOCAL_PASS_FILE)
  local zabbix_pass=$(getItemFromFile zabbix_pass $CONF_INFO_FILE.new)
  jsstr=$(cat <<EOF
mydb = db.getSiblingDB("admin");
mydb.changeUserPassword("$DB_QC_USER", "$newpass");
mydb.changeUserPassword("$DB_ZABBIX_USER", "$zabbix_pass");
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT

  # drop local database
  jsstr=$(cat <<EOF
mydb = db.getSiblingDB("local");
mydb.dropDatabase();
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT

  log "restore step 9"
  # stop mongod in admin mode
  shellStopMongodForAdmin

  # start mongod in normal mode
  _start

  # waiting for mongod status ok
  retry 60 3 0 msGetHostDbVersion -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)

  # init repl
  jsstr=$(cat <<EOF
rs.initiate(
  {
    _id: "$RS_NAME",
    members:[{_id: 0, host: "$MY_IP:$MY_PORT", priority: 2}]
  }
);
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)

  log "restore step 10"

  # add other members
  cnt=${#NODE_LIST[@]}
  log "restore step 11, cnt: $cnt"
  jsstr=""
  for((i=1;i<$cnt;i++)); do
    log "restore step 12 ,Node: ${NODE_LIST[i]} "
    if [ $i -eq $((cnt-1)) ]; then
      tmpstr="{host:\"$(getIp ${NODE_LIST[i]}):$MY_PORT\",priority: 0, hidden: true}"
    else
      tmpstr="{host:\"$(getIp ${NODE_LIST[i]}):$MY_PORT\",priority: 1}"
    fi
    jsstr="$jsstr;rs.add($tmpstr)"
  done
  log "restore step 13 ,jsstr: $jsstr"
  jsstr="${jsstr:1};"
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "restore step 14"
}


postRestore() {
  doWhenReplPostRestore
  rm -rf $BACKUP_FLAG_FILE
  enableHealthCheck
  # refresh zabbix's status
  updateZabbixConf
  refreshZabbixAgentStatus
}


doWhenReplPostRestore() {
  log "restore step 15"
  # waiting for 24 hours to restore data
  local cnt=${#NODE_LIST[@]}
  retry 86400 3 0 msIsReplStatusOk $cnt -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  sleep 5s

  local rlist=($(getRollingList))
  local tmpip=$(getIp ${rlist[0]})
  cnt=${#rlist[@]}
  log "restore step 16 , rlist: $rlist , tmpip: $tmpip , cnt: $cnt , myIp: $MY_IP"
  if [ ! $tmpip = "$MY_IP" ]; then log "$MY_ROLE: skip changing configue"; return 0; fi
  # change oplog
  for((i=0;i<$cnt;i++)); do
    tmpip=$(getIp ${rlist[i]})
      log "restore step 17 , tmpip: $tmpip"
    ssh root@$tmpip "appctl msReplChangeOplogSize"
  done
  # change other configure
  for((i=0;i<$cnt;i++)); do
    tmpip=$(getIp ${rlist[i]})
    log "restore step 18 , tmpip: $tmpip"
    ssh root@$tmpip "appctl msReplOnlyChangeConf"
  done
}

# change oplogSize
msReplChangeOplogSize() {
  local replication_oplogSizeMB=$(getItemFromFile replication_oplogSizeMB $CONF_INFO_FILE.new)
  local jsstr=$(cat <<EOF
db.adminCommand({replSetResizeOplog: 1, size: $replication_oplogSizeMB})
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "replication.oplogSizeMB changed"
}


msReplOnlyChangeConf() {
  local jsstr
  local setParameter_cursorTimeoutMillis
  local operationProfiling_mode
  local operationProfiling_mode_code
  local operationProfiling_slowOpThresholdMs
  setParameter_cursorTimeoutMillis=$(getItemFromFile setParameter_cursorTimeoutMillis $CONF_INFO_FILE.new)
  jsstr=$(cat <<EOF
db.adminCommand({setParameter:1,cursorTimeoutMillis:$setParameter_cursorTimeoutMillis})
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "setParameter.cursorTimeoutMillis changed"

  operationProfiling_mode=$(getItemFromFile operationProfiling_mode $CONF_INFO_FILE.new)
  operationProfiling_slowOpThresholdMs=$(getItemFromFile operationProfiling_slowOpThresholdMs $CONF_INFO_FILE.new)
  operationProfiling_mode_code=$(getOperationProfilingModeCode $operationProfiling_mode)
  jsstr=$(cat <<EOF
rs.slaveOk();
var dblist=db.adminCommand('listDatabases').databases;
var tmpdb;
for (i=0;i<dblist.length;i++) {
tmpdb=db.getSiblingDB(dblist[i].name);
tmpdb.setProfilingLevel($operationProfiling_mode_code, { slowms: $operationProfiling_slowOpThresholdMs });
}
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "operationProfiling changed"
}


getBackupNodeId() {
  log "start getBackupNodeId"

  local ip=$(getIp ${NODE_LIST[0]})
  if [ ! $ip = "$MY_IP" ]; then return 0; fi
  local cnt=${#NODE_LIST[@]}
  local tmpstr=""
  local tmpip
  for((i=0;i<$cnt;i++)); do
    tmpstr="$tmpstr,$(getNodeId ${NODE_LIST[i]})"
  done
  tmpstr="${tmpstr:1}"
  echo $tmpstr
}