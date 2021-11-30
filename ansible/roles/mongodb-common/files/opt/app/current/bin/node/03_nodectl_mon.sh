APPCTL_CMD_PATH=/usr/bin/appctl
isSingleThread() {
  local tmpcnt=$(pgrep -fa "$APPCTL_CMD_PATH $1" | wc -l)
  test $tmpcnt -eq 5
}

# remove " from jq results
moRmQuotation() {
  echo $@ | sed 's/"//g'
}

# remove " from jq results and calculate MB value
moRmQuotationMB() {
  local tmpstr=$(echo $@ | sed 's/"//g')
  echo "scale=0;$tmpstr/1024/1024" | bc
}

# calculate timespan, unit: minute
# scale_factor_when_display=0.1
moCalcTimespan() {
  local tmpstr=$(echo $@)
  local res=$(echo "scale=0;($tmpstr)/6" | sed 's/ /-/g' | bc | sed 's/-//g')
  echo $res
}

# unit "%"
# scale_factor_when_display=0.1
moCalcPer() {
  local type=$1
  shift
  local tmpstr=$(echo $@ | sed 's/"//g')
  local divisor
  local dividend
  local res
  if [ "$type" = 1 ]; then
    divisor=${tmpstr% *}
    dividend=${tmpstr##* }
    res=$(echo "scale=0;($divisor)*1000/$dividend" | sed 's/ /+/g' | bc)
  else
    divisor=${tmpstr%% *}
    dividend=${tmpstr#* }
    res=$(echo "scale=0;$divisor*1000/($dividend)" | sed 's/ /+/g' | bc)
  fi
  echo $res
}

msGetServerStatusForMonitor() {
  local tmpstr=$(runMongoCmd "JSON.stringify(db.serverStatus({\"repl\":1}))" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  echo "$tmpstr"
}

monitor() {
  if ! isSingleThread monitor; then log "a monitor is already running!"; return 1; fi
  local monpath=$REPL_MONITOR_ITEM_FILE
  local serverStr=$(msGetServerStatusForMonitor)
  local tmpstr
  local res
  local pipestr
  local pipep
  local title
  while read line; do
    title=$(echo $line | cut -d'/' -f1)
    pipestr=$(echo $line | cut -d'/' -f2)
    pipep=$(echo $line | cut -d'/' -f3)
    tmpstr=$(echo "$serverStr" |jq "$pipep")
    if [ ! -z "$pipestr" ]; then
      tmpstr=$(eval $pipestr $tmpstr)
    fi
    res="$res,\"$title\":$tmpstr"
  done < $monpath
  echo "{${res:1}}"
}

healthCheck() {
  if ! needHealthCheck; then log "skip health check"; return 0; fi
  if ! isSingleThread healthCheck; then log "a health check is already running!"; return 1; fi
  local srv=$(echo $SERVICES | cut -d'/' -f1).service
  local port=$(echo $SERVICES | cut -d':' -f2)
  if ! systemctl is-active $srv -q; then
    log "$srv has stopped!"
    return $ERR_SERVICE_STOPPED
  fi
  if [ ! $(lsof -b -i -s TCP:LISTEN | grep ':'$port | wc -l) = "1" ]; then
    log "port $port is not listened!"
    return $ERR_PORT_NOT_LISTENED
  fi

  if ! msIsReplStatusOk ${#NODE_LIST[@]} -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
    log "replica cluster is not health"
    return $ERR_REPL_NOT_HEALTH
  fi
  
  return 0
}

revive() {
  if ! isSingleThread revive; then log "a revive is already running!"; return 1; fi
  log "invoke revive"
  local srv=$(echo $SERVICES | cut -d'/' -f1).service
  local port=$(echo $SERVICES | cut -d':' -f2)
  if ! systemctl is-active $srv -q; then
    systemctl restart $srv
    log "$srv has been restarted!"
  else
    if [ ! $(lsof -b -i -s TCP:LISTEN | grep ':'$port | wc -l) = "1" ]; then
      log "port $port is not listened! do nothing"
    elif msIsReplOther -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then
      systemctl restart $srv
      log "status: OTHER, $srv has been restarted!"
    else
      log "status: NOT OTHER, do nothing"
    fi
  fi
}