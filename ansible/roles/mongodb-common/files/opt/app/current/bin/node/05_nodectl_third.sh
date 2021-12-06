reloadZabbix() {
  if [ $ZABBIX_ENABLED = "yes" ]; then
    systemctl restart zabbix-agent2.service || :
    log "zabbix-agent2 restarted"
  else
    systemctl stop zabbix-agent2.service || :
    log "zabbix-agent2 stopped"
  fi
}

reloadNodeExporter() {
  systemctl daemon-reload
  if [ $NODE_EXPORTER_ENABLED = "yes" ]; then
    systemctl restart node_exporter.service || :
    log "node_exporter restarted"
  else
    systemctl stop node_exporter.service || :
    log "node_exporter stopped"
  fi
}

reloadMongoDBExporter () {
  systemctl daemon-reload
  if [ $MONGODB_EXPORTER_ENABLED = "yes" ]; then
    systemctl restart mongodb_exporter.service || :
    log "mongodb_exporter restarted"
  else
    systemctl stop mongodb_exporter.service || :
    log "mongodb_exporter stopped"
  fi
}

reloadMongoShake() {
  log "start to reload mongoshake on host:$MY_IP"
  # 当副本数量大于1时， mongoshake只能在hidden节点上开启
  local cnt=${#NODE_LIST[@]}
  if [ $MONGOSHAKE_ENABLED = "yes" ]; then
    if [ "$cnt" -gt 1 ]; then
      if ! msIsHostHidden "$MY_IP:$MY_PORT" -H $MY_IP -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then 
        log "Mongoshake must be run on Hidden---$MY_IP:$MY_PORT"
        return 0
      fi
    fi
    systemctl restart mongoshake.service || :
    log "mongoshake started"
  else 
    systemctl stop mongoshake.service || :
  fi
}