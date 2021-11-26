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
  log "start to reload node_exporter"
  if [ $NODE_EXPORTER_ENABLED = "yes" ]; then
    # 需要先杀掉已经存在的nodeExporter进程
#     kill `netstat -nultp | grep node_exporter | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
    nohup /opt/node_exporter/current/node_exporter-1.2.2.linux-amd64/node_exporter  --web.listen-address=":$NODE_EXPORTER_PORT" &
    log "node_exporter restarted"
  else
    kill `netstat -nultp | grep $NODE_EXPORTER_PORT | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
    log "node_exporter stopped"
  fi

}

reloadCaddy() {
  if [ $CADDY_ENABLED = "yes" ]; then
    caddy start --config $CONF_CADDY_INFO_FILE
    log "caddy restarted"
  else
    caddy stop || :
    log "caddy stopped"
  fi
}

reloadMongoDBExporter () {
  log "start to reload mongodb_exporter"
  if [ $MONGODB_EXPORTER_ENABLED = "yes" ]; then
    kill `netstat -nultp | grep mongodb_exporter | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
    nohup /usr/bin/mongodb_exporter --mongodb.uri=mongodb://$DB_MONITOR_USER:$DB_MONITOR_PWD@localhost:$MY_PORT --web.listen-address=:$MONGODB_EXPORTER_PORT &
    log "mongodb_exporter restarted"
  else
    kill `netstat -nultp | grep $MONGODB_EXPORTER_PORT | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
    log "mongodb_exporter stopped"
  fi
}

reloadMongoShake() {
  log "start to reload mongoshake"
  kill `netstat -nultp | grep collector.li | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
  if [ $MONGOSHAKE_ENABLED = "yes" ]; then
    touch $MONGOSHAKE_FLAG_FILE
    nohup /opt/mongo-shake/current/mongo-shake-v2.6.5/collector.linux -conf=$CONF_MONGOSHAKE_FILE &
    log "mongoshake started"
  fi
  rm -rf $MONGOSHAKE_FLAG_FILE || : 

}