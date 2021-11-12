# msInitRepl
# init replicaset
#  first node: priority 2
#  other node: priority 1
#  last node: priority 0, hidden true
# init readonly replicaset
#  first node: priority 2
#  other node: priority 1
init() {
:
}

preStart() {
:
}

start() {
:
}

stop() {
:
}

clearNodeFirstCreateFlag() {
  if [ -f $NODE_FIRST_CREATE_FLAG_FILE ]; then rm -f $NODE_FIRST_CREATE_FLAG_FILE; fi
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

msEnableBalancer() {
  if runMongoCmd "sh.setBalancerState(true)" $@; then
    log "enable balancer: succeeded"
  else
    log "enable balancer: failed"
  fi
}


MONGOD_BIN=/opt/mongodb/current/bin/mongod
shellStartMongodForAdmin() {
  runuser mongod -g svc -s "/bin/bash" -c "$MONGOD_BIN -f $MONGODB_CONF_PATH/mongo-admin.conf --setParameter disableLogicalSessionCacheRefresh=true"
}

shellStopMongodForAdmin() {
  runuser mongod -g svc -s "/bin/bash" -c "$MONGOD_BIN -f $MONGODB_CONF_PATH/mongo-admin.conf --shutdown"
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

msDisableBalancer() {
  local tmpstr=$(runMongoCmd "JSON.stringify(sh.stopBalancer())" $@)
  local res=$(echo "$tmpstr" | jq '.ok')
  test $res = 1
}

msForceStepDown() {
  runMongoCmd "rs.stepDown()" $@ || :
}
