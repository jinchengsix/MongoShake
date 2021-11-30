# reloadZabbix() {
  # log "temporarily ingore zabbix agent2 for ubuntu20.04 "
  # if [ $ZABBIX_ENABLED = "yes" ]; then
  #   systemctl restart zabbix-agent2.service || :
  #   log "zabbix-agent2 restarted"
  # else
  #   systemctl stop zabbix-agent2.service || :
  #   log "zabbix-agent2 stopped"
  # fi
# }

reloadNodeExporter() {
  systemctl daemon-reload
  log "start to reload node_exporter"
  if [ $NODE_EXPORTER_ENABLED = "yes" ]; then
    systemctl restart node_exporter.service || :
    log "node_exporter restarted"
  else
    systemctl stop node_exporter.service || :
    log "node_exporter stopped"
  fi

}

reloadCaddy() {
  if [ $CADDY_ENABLED = "yes" ]; then
    systemctl restart caddy.service || :
    log "caddy restarted"
  else
    systemctl stop caddy.service || :
    log "caddy stopped"
  fi
}

reloadMongoDBExporter () {
  systemctl daemon-reload
  log "start to reload mongodb_exporter"
  if [ $MONGODB_EXPORTER_ENABLED = "yes" ]; then
    systemctl restart mongodb_exporter.service || :
    log "mongodb_exporter restarted"
  else
    systemctl stop mongodb_exporter.service || :
    log "mongodb_exporter stopped"
  fi
}

reloadMongoShake() {
  log "start to reload mongoshake"
  # 当副本数量大于1时， mongoshake只能在hidden节点上开启
  local cnt=${#NODE_LIST[@]}
  if [ $MONGOSHAKE_ENABLED = "yes" ]; then
    if [ "$cnt" -gt 1 ]; then
      if ! msIsHostHidden "$MY_IP:$MY_PORT" -H $MY_IP -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then 
        return $ERR_MONGOSHAKE_ON_HIDDEN
      fi
    fi
    touch $MONGOSHAKE_FLAG_FILE
    systemctl restart mongoshake.service || :
    log "mongoshake started"
  else 
    systemctl stop mongoshake.service || :
  fi
  rm -rf $MONGOSHAKE_FLAG_FILE || : 

}