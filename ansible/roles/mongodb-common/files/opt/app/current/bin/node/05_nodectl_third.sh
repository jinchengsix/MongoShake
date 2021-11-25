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
  local nEnabled=$(getItemFromFile nEnabled $CONF_NODE_EXPORTER_FILE)
  local ListenPort=$(getItemFromFile nPort $CONF_NODE_EXPORTER_FILE)
  if [ $nEnabled = "yes" ]; then
    # 需要先杀掉已经存在的nodeExporter进程
#     kill `netstat -nultp | grep node_exporter | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
    nohup /opt/node_exporter/current/node_exporter-1.2.2.linux-amd64/node_exporter  --web.listen-address=":$ListenPort" &
    log "node_exporter restarted"
  else
    kill `netstat -nultp | grep $ListenPort | awk '{print $7}' | awk -F "/" '{print $1}'`   || :
    log "node_exporter stopped"
  fi

}

reloadCaddy() {
  log "start to reload caddy"
  local cEnabled=$(getItemFromFile cEnabled $CONF_CADDY_ENV_INFO_FILE)
  if [ $cEnabled = "yes" ]; then
    caddy start --config $CONF_CADDY_INFO_FILE
    log "caddy restarted"
  else
    caddy stop || :
    log "caddy stopped"
  fi
}