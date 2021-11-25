########## start ##########
updateMongoConf() {
  if ! diff $CONF_INFO_FILE $CONF_INFO_FILE.new; then
    cat $CONF_INFO_FILE.new > $CONF_INFO_FILE
    createMongoConf
  fi
}

updateHostsInfo() {
  if ! diff $HOSTS_INFO_FILE $HOSTS_INFO_FILE.new; then
    cat $HOSTS_INFO_FILE.new > $HOSTS_INFO_FILE
  fi
}


msGetReplCfgFromLocal() {
  local jsstr=$(cat <<EOF
mydb = db.getSiblingDB("local")
JSON.stringify(mydb.system.replset.findOne())
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT
}

msUpdateReplCfgToLocal() {
  local jsstr=$(cat <<EOF
newlist=[$1]
mydb = db.getSiblingDB('local')
cfg = mydb.system.replset.findOne()
cnt = cfg.members.length
for(i=0; i<cnt; i++) {
  cfg.members[i].host=newlist[i]
}
mydb.system.replset.update({"_id":"$RS_NAME"},cfg)
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT
}

changeReplNodeNetInfo() {
  # start mongod in admin mode
  shellStartMongodForAdmin

  local replcfg
  retry 60 3 0 msGetHostDbVersion -P $NET_MAINTAIN_PORT
  replcfg=$(msGetReplCfgFromLocal)
  local cnt=${#NODE_LIST[@]}
  local oldinfo=$(getItemFromFile NODE_LIST $HOSTS_INFO_FILE)
  local oldport=$(getItemFromFile PORT $HOSTS_INFO_FILE)
  local tmpstr
  local newlist
  for((i=0;i<$cnt;i++)); do
    # old ip:port
    tmpstr=$(echo "$replcfg" | jq ".members[$i] | .host" | sed s/\"//g)
    # nodeid
    tmpstr=$(echo "$oldinfo" | sed 's/\/cln-/:'$oldport'\/cln-/g' | sed 's/ /\n/g' | sed -n /$tmpstr/p)
    tmpstr=$(getNodeId $tmpstr)
    # newip
    tmpstr=$(echo ${NODE_LIST[@]} | grep -o '[[:digit:].]\+/'$tmpstr | cut -d'/' -f1)
    newlist="$newlist\"$tmpstr:$MY_PORT\","
  done
  # update replicaset config
  # js array: "ip:port","ip:port","ip:port"
  newlist=${newlist:0:-1}
  msUpdateReplCfgToLocal "$newlist"

  # stop mongod in admin mode
  shellStopMongodForAdmin
}

start() {
  if [ $CHANGE_VXNET_FLAG = "true" ]; then
    changeReplNodeNetInfo
    log "vxnet has been changed!"
  fi
  # updat conf files
  updateHostsInfo
  updateMongoConf
  _start
  if ! isNodeFirstCreate; then enableHealthCheck; fi
  clearNodeFirstCreateFlag
  # start zabbix-agent2
  # updateZabbixConf
  # refreshZabbixAgentStatus
}

########## init ##########
# msInitRepl
# init replicaset
#  first node: priority 2
#  other node: priority 1
#  last node: priority 0, hidden true
# init readonly replicaset
#  first node: priority 2
#  other node: priority 1
msInitRepl() {
  local slist=($(getInitNodeList))
  local cnt=${#slist[@]}
  
  local curmem=''
  local memberstr=''
  for((i=0; i<$cnt; i++)); do
    if [ $i -eq 0 ]; then
      curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$MY_PORT\",priority: 2}"
    elif [ $i -eq $((cnt-1)) ]; then
      curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$MY_PORT\",priority: 0, hidden: true}"
    else
      curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$MY_PORT\",priority: 1}"
    fi
    
    memberstr="$memberstr$curmem,"
  done
  memberstr=${memberstr:0:-1}

  local initjs=$(cat <<EOF
rs.initiate({
  _id:"$RS_NAME",
  members:[$memberstr]
})
EOF
  )

  runMongoCmd "$initjs" -P $MY_PORT
}

msAddLocalSysUser() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$DB_QC_USER",
    pwd: "$(cat $DB_QC_LOCAL_PASS_FILE)",
    roles: [ { role: "root", db: "admin" },{ role: "__system", db: "admin" } ]
  }
)
EOF
  )
  runMongoCmd "$jsstr" -P $MY_PORT
}

msAddUserRoot() {
  local user_pass="$(getItemFromFile user_pass $CONF_INFO_FILE)"
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "root",
    pwd: "$user_pass",
    roles: [ { role: "root", db: "admin" } ]
  }
)
EOF
  )
  runMongoCmd "$jsstr" $@
}

msAddUserMonitor() {
  local monitor_pass="$(getItemFromFile monitor_pass $CONF_INFO_FILE)"
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$DB_MONITOR_USER",
    pwd: "$monitor_pass",
    roles: [ { role: "clusterMonitor", db: "admin" } ]
  }
)
EOF
  )
  runMongoCmd "$jsstr" $@
}

msUpdateQingCloudControl() {
  local jsstr=$(cat <<EOF
cfg=db.getSiblingDB("config");
cfg.QingCloudControl.findAndModify(
  {
    query:{_id:"QcCtrlDoc"},
    update:{\$inc:{counter:1}},
    new: true,
    upsert: true,
    writeConcern:{w:"majority",wtimeout:15000}
  }
);
EOF
  )
  runMongoCmd "$jsstr" $@
}

init() {
  # except scaleIn and scaleOut
  if [ $ADDING_HOSTS_FLAG = "true" ] || [ $DELETING_HOSTS_FLAG = "true" ] ; then return 0; fi
  
  local slist=($(getInitNodeList))
  if [ ! $(getSid ${slist[0]}) = $MY_SID ]; then return 0; fi
  log "init replicaset begin ..."
  retry 60 3 0 msInitRepl
  retry 60 3 0 msIsReplStatusOk ${#NODE_LIST[@]} -P $MY_PORT
  retry 60 3 0 msIsHostMaster "$MY_IP:$MY_PORT" -P $MY_PORT
  log "add local sys user"
  retry 60 3 0 msAddLocalSysUser
  log "add root user"
  retry 60 3 0 msAddUserRoot -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "add zabbix user"
  retry 60 3 0 msAddUserMonitor -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "update QingCloudControl database"
  msUpdateQingCloudControl -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "init replicaset done"
  enableHealthCheck
}

########## stop ##########
stop() {
  local cnt=${#NODE_LIST[@]}
  if [ "$cnt" -gt 1 ]; then
    if isMeMaster; then
      runMongoCmd "rs.stepDown()" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE) || :
    fi
    # wait for 30 minutes
    retry 1800 3 0 isMeNotMaster
  fi
  _stop
  disableHealthCheck
  log "node stopped"
}

########## precheck ##########
changeVxnetPreCheck() {
  local cnt=${#NODE_LIST[@]}
  if ! msIsReplStatusOk $cnt -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
    log "replica cluster is not health"
    return $ERR_REPL_NOT_HEALTH
  fi

  return 0
}
