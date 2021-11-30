scaleInPreCheck() {
  log "scaleInPreCheck step 1, myIp:$MY_IP "

  local nodeNum=${#NODE_LIST[@]}
  local deleteNum=${#DELETING_LIST[@]}
  log "scaleInPreCheck step 2, nodeNum: $nodeNum, deleteNum: $deleteNum"

  #删除数量必须为偶数个
  if [ `expr $deleteNum % 2` -eq 1 ]; then
    log "scaleInPreCheck step 3"
    return $ERR_DELETE_NODES_NUM_SHOULD_BE_EVEN;
  fi
  
  local tmpip;
  #不允许删除主节点
  for((i=0;i<$deleteNum;i++)); do
    tmpip=$(getIp ${DELETING_LIST[i]})
    if msIsHostMaster "$tmpip:$MY_PORT" -H $tmpip -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
      log "scaleInPreCheck step 3"
      return $ERR_PRIMARY_DELETE_NOT_ALLOWED;
    fi
  done

  # 当集群为五节点时，且删除数量为2时，不允许删除hidden节点
  if [ $nodeNum -eq 5 ] && [ $deleteNum -eq 2 ]; then
    log "scaleInPreCheck step 4"
    checkIfDeleteHidden $deleteNum
  fi

  # 当集群为七节点时，且删除数量小于6时，不允许删除hidden节点
  if [ $nodeNum -eq 7 ] && [ $deleteNum -lt 6 ]; then
    log "scaleInPreCheck step 5"
    checkIfDeleteHidden $deleteNum
  fi
}

checkIfDeleteHidden() {
  for((i=0;i<$1;i++)); do
      tmpip=$(getIp ${DELETING_LIST[i]})
      if msIsHostHidden "$tmpip:$MY_PORT" -H $MY_IP -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
        log "scaleInPreCheck checkIfDeleteHidden,hostInfo:$tmpip:$MY_PORT"
        return $ERR_HIDDEN_DELETE_NOT_ALLOWED;
      fi
  done
}

scaleIn() {
  log "scaleIn step 1, myIp:$MY_IP"
  if isMeMaster; then
    retry 60 3 0 deleteNodeForRepl
  fi
  updateMongoConf 
  updateHostsInfo
}

scaleOut() {
  log "start to scaleOut"
  if isMeMaster; then
    retry 60 3 0 addNodeForRepl
  fi
  updateMongoConf 
  updateHostsInfo
}

addNodeForRepl() {
  local cnt=${#ADDING_LIST[@]}
  local jsstr=""
  local num=${#NODE_LIST[@]}

  for((i=0;i<$cnt;i++)); do
    if [ $((num-cnt)) -eq 1 ] && [ $i -eq 0 ]; then 
      tmpstr="{host:\"$(getIp ${ADDING_LIST[i]}):$MY_PORT\",priority: 0, hidden: true}"
      jsstr="$jsstr;rs.add($tmpstr)"
      continue
    fi
    tmpstr="{host:\"$(getIp ${ADDING_LIST[i]}):$MY_PORT\",priority: 1}"
    jsstr="$jsstr;rs.add($tmpstr)"
  done
  jsstr="${jsstr:1};"
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
}

deleteNodeForRepl() {
  local cnt=${#DELETING_LIST[@]}
  local jsstr=""
  log "scaleIn step 2, cnt:$cnt"
  for((i=0;i<$cnt;i++)); do
    local deleteIp=$(getIp ${DELETING_LIST[i]})
    log "scaleIn step 3, deleteIp:$deleteIp"
    runMongoCmd "rs.remove(\"$deleteIp:$MY_PORT\")" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  done

}

clusterPreInit() {
  # folder
  mkdir -p $MONGODB_DATA_PATH $MONGODB_LOG_PATH $MONGODB_CONF_PATH
  chown -R mongod:svc $MONGODB_DATA_PATH $MONGODB_LOG_PATH $MONGODB_CONF_PATH
  # chown -R zabbix:zabbix $ZABBIX_LOG_PATH
  # first create flag
  touch $NODE_FIRST_CREATE_FLAG_FILE
  # repl.key
  echo "$GLOBAL_UUID" | base64 > "$MONGODB_CONF_PATH/repl.key"
  chown mongod:svc $MONGODB_CONF_PATH/repl.key
  chmod 0400 $MONGODB_CONF_PATH/repl.key
  #qc_local_pass
  local encrypted=$(echo -n ${GLOBAL_UUID}${CLUSTER_ID} | sha256sum | base64)
  echo ${encrypted:16:16} > $DB_QC_LOCAL_PASS_FILE
  #create config files
  touch $MONGODB_CONF_PATH/mongo.conf
  chown mongod:svc $MONGODB_CONF_PATH/mongo.conf
  #disable health check
  disableHealthCheck
}

# check if node is scaling
# 1: scaleIn
# 0: no change
# 2: scaleOut
getScalingStatus() {
  local oldlist=($(getItemFromFile NODE_LIST $HOSTS_INFO_FILE))
  local newlist=($(getItemFromFile NODE_LIST $HOSTS_INFO_FILE.new))
  local oldcnt=${#oldlist[@]}
  local newcnt=${#newlist[@]}
  if (($oldcnt < $newcnt)); then
    echo 2
  elif (($oldcnt > $newcnt)); then
    echo 1
  else
    echo 0
  fi
}

# run at mongos
msAddShardNodeByGidList() {
  local glist=($(echo $@))
  local cnt=${#glist[@]}
  local subcnt
  local tmpstr
  local currepl
  local tmpip
  for((i=0;i<$cnt;i++)); do
    tmplist=($(eval echo \${INFO_SHARD_${glist[i]}_LIST[@]}))
    currepl=$(eval echo \$INFO_SHARD_${glist[i]}_RSNAME)
    subcnt=${#tmplist[@]}
    tmpstr="$tmpstr;sh.addShard(\"$currepl/"
    retry 60 3 0 msIsReplStatusOk $subcnt -H $(getIp ${tmplist[0]}) -P $INFO_SHARD_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
    for((j=0;j<$subcnt;j++)); do
      tmpip=$(getIp ${tmplist[j]})
      if msIsHostHidden "$tmpip:$INFO_SHARD_PORT" -H $tmpip -P $INFO_SHARD_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then continue; fi
      tmpstr="$tmpstr$(getIp ${tmplist[j]}):$INFO_SHARD_PORT,"
    done
    tmpstr="${tmpstr:0:-1}\")"
  done
  tmpstr="${tmpstr:1};"
  echo $tmpstr
  runMongoCmd "$tmpstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
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

# change user_pass(root)
msReplChangeRootPass() {
  if ! isMeMaster; then log "change DB_ROOT_PWD, skip"; return 0; fi
  local user_pass=$(getItemFromFile user_pass $CONF_INFO_FILE.new)
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.changeUserPassword("$DB_ROOT_USER", "$user_pass")
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "user $DB_ROOT_USER's password has been changed"
}

# change monitor_pass
msReplChangeMonitorPass() {
  if ! isMeMaster; then log "change DB_MONITOR_PWD, skip"; return 0; fi
  local monitor_pass=$(getItemFromFile monitor_pass $CONF_INFO_FILE.new)
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.changeUserPassword("$DB_MONITOR_USER", "$monitor_pass")
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "user $DB_MONITOR_USER's password has been changed"
}

# change conf according to $CONF_INFO_FILE.new
msReplChangeConf() {
  local tmpcnt
  local jsstr
  local setParameter_cursorTimeoutMillis
  local operationProfiling_mode
  local operationProfiling_mode_code
  local operationProfiling_slowOpThresholdMs

  # user_pass (root)
  tmpcnt=$(diff $CONF_INFO_FILE $CONF_INFO_FILE.new | grep user_pass | wc -l) || :
  if (($tmpcnt > 0)); then
    msReplChangeRootPass
    return 0
  fi

  # monitor_pass
  tmpcnt=$(diff $CONF_INFO_FILE $CONF_INFO_FILE.new | grep monitor_pass | wc -l) || :
  if (($tmpcnt > 0)); then
    msReplChangeMonitorPass
    return 0
  fi

  # replication_oplogSizeMB
  tmpcnt=$(diff $CONF_INFO_FILE $CONF_INFO_FILE.new | grep oplogSizeMB | wc -l) || :
  if (($tmpcnt > 0)); then
    msReplChangeOplogSize
  fi

  # setParameter_cursorTimeoutMillis
  tmpcnt=$(diff $CONF_INFO_FILE $CONF_INFO_FILE.new | grep setParameter | wc -l) || :
  if (($tmpcnt > 0)); then
    setParameter_cursorTimeoutMillis=$(getItemFromFile setParameter_cursorTimeoutMillis $CONF_INFO_FILE.new)
    jsstr=$(cat <<EOF
db.adminCommand({setParameter:1,cursorTimeoutMillis:$setParameter_cursorTimeoutMillis})
EOF
    )
    runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
    log "setParameter.cursorTimeoutMillis changed"
  fi

  # operationProfiling_mode
  # operationProfiling_slowOpThresholdMs
  tmpcnt=$(diff $CONF_INFO_FILE $CONF_INFO_FILE.new | grep operationProfiling | wc -l) || :
  if (($tmpcnt > 0)); then
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
  fi
}

# check if node is scaling
# 1: scaleIn
# 0: no change
# 2: scaleOut
getScalingStatus() {
  local oldlist=($(getItemFromFile NODE_LIST $HOSTS_INFO_FILE))
  local newlist=($(getItemFromFile NODE_LIST $HOSTS_INFO_FILE.new))
  local oldcnt=${#oldlist[@]}
  local newcnt=${#newlist[@]}
  if (($oldcnt < $newcnt)); then
    echo 2
  elif (($oldcnt > $newcnt)); then
    echo 1
  else
    echo 0
  fi
}

checkConfdChange() {
  if [ $UPGRADING_FLAG = "true" ]; then
    log "cluster upgrading, skipping"
    return 0
  fi

  if [ ! -d /data/appctl/logs ]; then
    # first create
    log "cluster pre-init"
    clusterPreInit
    return 0
  fi

  if [ -f $BACKUP_FLAG_FILE ]; then
    log "restore from backup, skipping"
    return 0
  fi

  if [ $VERTICAL_SCALING_FLAG = "true" ] || [ $ADDING_HOSTS_FLAG = "true" ] || [ $DELETING_HOSTS_FLAG = "true" ] || [ $CHANGE_VXNET_FLAG = "true" ]; then return 0; fi
  local sstatus=$(getScalingStatus)
  case $sstatus in
    "0") :;;
    "1") updateHostsInfo; return 0;;
    "2") return 0;;
  esac
  
  # replicaset config changed
  doWhenReplConfChanged
}

doWhenReplConfChanged() {
  if diff $CONF_INFO_FILE $CONF_INFO_FILE.new; then return 0; fi
  local rlist=($(getRollingList))
  local cnt=${#rlist[@]}
  local tmpcnt
  local tmpip
  tmpip=$(getIp ${rlist[0]})
  if [ ! $tmpip = "$MY_IP" ]; then log "$MY_ROLE: skip changing configue"; return 0; fi

  if isMongodNeedRestart; then
    # oplogSizeMB check first
    tmpcnt=$(diff $CONF_INFO_FILE $CONF_INFO_FILE.new | grep oplogSizeMB | wc -l) || :
    if (($tmpcnt > 0)); then
      for((i=0;i<$cnt;i++)); do
        tmpip=$(getIp ${rlist[i]})
        ssh root@$tmpip "appctl msReplChangeOplogSize"
      done
    fi

    log "rolling restart mongod.service"
    for((i=0;i<$cnt;i++)); do
      tmpip=$(getIp ${rlist[i]})
      if msIsHostMaster "$tmpip:$MY_PORT" -H $tmpip -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
        msForceStepDown -H $tmpip -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
      fi
      ssh root@$tmpip "appctl updateMongoConf && systemctl restart mongod.service"
      retry 60 3 0 msIsReplStatusOk $cnt -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
    done
  else
    for((i=0;i<$cnt;i++)); do
      tmpip=$(getIp ${rlist[i]})
      ssh root@$tmpip "appctl msReplChangeConf && appctl updateMongoConf"
    done
  fi
}


