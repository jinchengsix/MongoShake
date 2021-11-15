backup() {
  log "info"
  # set backup flag
  touch $BACKUP_FLAG_FILE
}

cleanup() {
  log "info"
  # reset backup flag
  rm -rf $BACKUP_FLAG_FILE
}

restore() {
  preRestore
  doWhenRestoreRepl
  postRestore
}

preRestore() {
  disableHealthCheck

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
  
  # sync from host.info.new & recreate mongo conf
  updateHostsInfo
  updateMongoConf

  local cnt=${#NODE_LIST[@]}
  local ip=$(getIp ${NODE_LIST[0]})
  if [ ! $ip = "$MY_IP" ]; then
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

  # add other members
  cnt=${#NODE_LIST[@]}
  jsstr=""
  for((i=1;i<$cnt;i++)); do
    if [ $i -eq $((cnt-1)) ]; then
      tmpstr="{host:\"$(getIp ${NODE_LIST[i]}):$MY_PORT\",priority: 0, hidden: true}"
    else
      tmpstr="{host:\"$(getIp ${NODE_LIST[i]}):$MY_PORT\",priority: 1}"
    fi
    jsstr="$jsstr;rs.add($tmpstr)"
  done
  jsstr="${jsstr:1};"
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
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
  
  # waiting for 24 hours to restore data
  local cnt=${#NODE_LIST[@]}
  retry 86400 3 0 msIsReplStatusOk $cnt -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  sleep 5s

  local rlist=($(getRollingList))
  local tmpip=$(getIp ${rlist[0]})
  cnt=${#rlist[@]}
  if [ ! $tmpip = "$MY_IP" ]; then log "$MY_ROLE: skip changing configue"; return 0; fi
  # change oplog
  for((i=0;i<$cnt;i++)); do
    tmpip=$(getIp ${rlist[i]})
    ssh root@$tmpip "appctl msReplChangeOplogSize"
  done
  # change other configure
  for((i=0;i<$cnt;i++)); do
    tmpip=$(getIp ${rlist[i]})
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