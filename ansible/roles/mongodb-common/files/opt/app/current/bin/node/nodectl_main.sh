# sourced by /opt/app/current/bin/ctl.sh
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


# msInitRepl
# init replicaset
#  first node: priority 2
#  other node: priority 1
#  last node: priority 0, hidden true
# init readonly replicaset
#  first node: priority 2
#  other node: priority 1
init() {

}

preStart() {

}

start() {

}

stop() {

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
