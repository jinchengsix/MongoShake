# create or modify the $DB_QC_USER
msModifyLocalSysUser() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
user = admin.getUser("$DB_QC_USER")
if (user==null) {
  admin.createUser(
    {
      user: "$DB_QC_USER",
      pwd: "$(cat $DB_QC_LOCAL_PASS_FILE)",
      roles: [ { role: "root", db: "admin" },{ role: "__system", db: "admin" } ]
    }
  )
}
else {
  admin.updateUser("$DB_QC_USER",
    {
      pwd: "$(cat $DB_QC_LOCAL_PASS_FILE)",
      roles: [ { role: "root", db: "admin" },{ role: "__system", db: "admin" } ]
    }
  )
}
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT
}

msUpdateReplCfgWhenUpgrade() {
  local jsstr=$(cat <<EOF
newlist=[$1]
mydb = db.getSiblingDB('local')
cfg = mydb.system.replset.findOne()
cnt = cfg.members.length
flag = false
for(i=0; i<cnt; i++) {
  cfg.members[i].host=newlist[i]
  if (!flag) {
    if (cfg.members[i].priority==2) { continue }
    cfg.members[i].hidden=true
    cfg.members[i].priority=0
    flag=true
  }
}
mydb.system.replset.update({"_id":"$RS_NAME"},cfg)
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT
}

changeMemberNetPort() {
  local replcfg
  retry 60 3 0 msGetHostDbVersion -P $NET_MAINTAIN_PORT
  replcfg=$(msGetReplCfgFromLocal)
  echo "$replcfg" > /data/upback34/replcfg
  local cnt=${#NODE_LIST[@]}
  local oldinfo=$(getItemFromFile NODE_LIST $HOSTS_INFO_FILE)
  local oldport=$(getItemFromFile PORT $HOSTS_INFO_FILE)
  local tmpstr
  local newlist
  for((i=0;i<$cnt;i++)); do
    # old ip:port
    tmpstr=$(echo "$replcfg" | jq ".members[$i] | .host" | sed s/\"//g | cut -d':' -f1)
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
  msUpdateReplCfgWhenUpgrade "$newlist"
}

upgrade() {
  log "upgrade: init folders and files"
  clusterPreInit
  mkdir -p /data/upback34 && cp /data/pitrix.pwd /data/mongod_env /data/upback34
  cp /opt/app/current/bin/node/rollback.sh /data/upback34
  rm -rf /data/mongodb-data
  ln -s /data/mongodb /data/mongodb-data
  # updat conf files
  updateHostsInfo
  updateMongoConf
  log "upgrade: change metadatas"
  if ! shellStartMongodForAdmin; then
    log "Can not start mongod in admin mode"
    return $ERR_UPGRADE_MODE_START
  fi
  retry 60 3 0 msGetHostDbVersion -P $NET_MAINTAIN_PORT
  # change qc_master's password
  if ! msModifyLocalSysUser; then
    log "Can not modify qc_master's password"
    return $ERR_UPGRADE_SYS_PASSWORD
  fi
  # change members' port
  if ! changeMemberNetPort; then
    log "Can not change net port"
    return $ERR_UPGRADE_NET_PORT
  fi
  clearNodeFirstCreateFlag
  if ! shellStopMongodForAdmin; then
    log "Can not stop mongod in admin mode"
    return $ERR_UPGRADE_MODE_STOP
  fi
  log "upgrade: done"
}

rollback() {
  :
}