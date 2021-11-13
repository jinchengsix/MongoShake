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

updateZabbixConf() {
  if ! diff $CONF_ZABBIX_INFO_FILE $CONF_ZABBIX_INFO_FILE.new; then
    cat $CONF_ZABBIX_INFO_FILE.new > $CONF_ZABBIX_INFO_FILE
    createZabbixConf
  fi
}

refreshZabbixAgentStatus() {
  zEnabled=$(getItemFromFile Enabled $CONF_ZABBIX_INFO_FILE)
  if [ $zEnabled = "yes" ]; then
    systemctl restart zabbix-agent2.service || :
    log "zabbix-agent2 restarted"
  else
    systemctl stop zabbix-agent2.service || :
    log "zabbix-agent2 stopped"
  fi
}

start() {
  # updat conf files
  updateHostsInfo
  updateMongoConf
  _start
  if ! isNodeFirstCreate; then enableHealthCheck; fi
  clearNodeFirstCreateFlag
  # start zabbix-agent2
  updateZabbixConf
  refreshZabbixAgentStatus
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

  local initjs=''
  if [ $MY_ROLE = "cs_node" ]; then
    initjs=$(cat <<EOF
rs.initiate({
  _id:"$RS_NAME",
  configsvr: true,
  members:[$memberstr]
})
EOF
    )
  else
    initjs=$(cat <<EOF
rs.initiate({
  _id:"$RS_NAME",
  members:[$memberstr]
})
EOF
    )
  fi

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

msAddUserZabbix() {
  local zabbix_pass="$(getItemFromFile zabbix_pass $CONF_INFO_FILE)"
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$DB_ZABBIX_USER",
    pwd: "$zabbix_pass",
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
  retry 60 3 0 msAddUserZabbix -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "update QingCloudControl database"
  msUpdateQingCloudControl -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
  log "init replicaset done"
  enableHealthCheck
}

########## stop ##########
stop() {
:
}

msForceStepDown() {
  runMongoCmd "rs.stepDown()" $@ || :
}
