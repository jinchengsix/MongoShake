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

  if [ $MONGOSHAKE_ENABLED = "yes" ]; then
    touch $MONGOSHAKE_FLAG_FILE
    systemctl restart mongoshake.service || :
    log "mongoshake started"
  else 
    systemctl stop mongoshake.service || :
  fi
  rm -rf $MONGOSHAKE_FLAG_FILE || : 

}