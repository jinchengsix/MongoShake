# error code
ERR_PORT_NOT_LISTEN=500
ERR_PROCESS_NOT_EXIST=501

# path info
REPL_MONITOR_ITEM_FILE=/opt/app/current/bin/node/repl.monitor
IGNORE_HEALTH_CHECK_FLAG_FILE=/data/appctl/data/ignore_health.check.flag
MONGOSHAKE_CONF=/opt/app/current/conf/mongoshake/mongoshake.conf
BEING_HEALTH_CHECKED_FLAG=/data/appctl/data/being_health_checked.flag
BEING_REVIVED_FLAG=/data/appctl/data/being_revived.flag
MONITOR_DIR=/opt/mongo-shake/metrics
MONITOR_ITEM_EXECUTOR=/opt/mongo-shake/metrics/executor.metrics
MONITOR_ITEM_PERSIST=/opt/mongo-shake/metrics/persist.metrics
MONITOR_ITEM_QUEUE=/opt/mongo-shake/metrics/queue.metrics
MONITOR_ITEM_REPL=/opt/mongo-shake/metrics/repl.metrics
MONITOR_ITEM_SENTINEL=/opt/mongo-shake/metrics/sentinel.metrics
MONITOR_ITEM_SENTINEL_OPTIONS=/opt/mongo-shake/metrics/sentinel_options.metrics
MONITOR_ITEM_WORKER=/opt/mongo-shake/metrics/worker.metrics
MONITOR_ITEM_PROGRESS=/opt/mongo-shake/metrics/progress.metrics
MONITOR_ITEM_TMP=/opt/mongo-shake/metrics/tmp.metrics
MONITOR_TEMPLATE=/opt/app/current/bin/node/item.monitor


start(){
    log ">>>>> start <<<<<"
    systemctl start mongoshake.service
}

stop(){
    log ">>>>> stop <<<<<"
    systemctl stop mongoshake.service
}

reload(){
    log ">>>>> reload <<<<<"
    systemctl restart mongoshake.service
}

monitor(){
    log ">>>>> monitor <<<<<"
    if [ ! -d $MONITOR_DIR ];then
        mkdir -p $MONITOR_DIR 
    fi
    local res
    local group
    local title
    local value
    
    local incr_port=$(getItemFromFile incr_sync.http_port $MONGOSHAKE_CONF)
    local full_port=$(getItemFromFile full_sync.http_port $MONGOSHAKE_CONF)
    initIncrFile
    initFullFile

    if [ ! -z "$(getPidByNetstat $incr_port)" ]; then 
        getMonitorItem $incr_port $MONITOR_ITEM_EXECUTOR "executor"
        getMonitorItem $incr_port $MONITOR_ITEM_PERSIST "persist"
        getMonitorItem $incr_port $MONITOR_ITEM_REPL "repl"
    fi

    if [ ! -z "$(getPidByNetstat $full_port)" ]; then 
        getMonitorItem $full_port $MONITOR_ITEM_PROGRESS "progress"
    fi

    while read line; do
        group=$(echo $line | cut -d'/' -f1)
        title=$(echo $line | cut -d'/' -f2)
        pipestr=$(echo $line | cut -d'/' -f3)
        if [ "$group" = "persist" ]; then
            value=$(cat $MONITOR_ITEM_PERSIST | jq "$pipestr")
        fi

        if [ "$group" = "repl" ]; then
            value=$(cat $MONITOR_ITEM_REPL | jq "$pipestr")
        fi

        if [ "$group" = "progress" ]; then
            value=$(cat $MONITOR_ITEM_PROGRESS | jq "$pipestr")
        fi

        if [ "$group" = "executor" ]; then
            cat $MONITOR_ITEM_EXECUTOR | jq "$pipestr" > $MONITOR_ITEM_TMP
            value=$(echo $(echo -n `cat $MONITOR_ITEM_TMP` | tr ' ' '+') | bc)
        fi
        res="$res,\"$title\":$value"
        done < $MONITOR_TEMPLATE
    echo "{${res:1}}"
}

getMonitorItem(){
    curl 127.0.0.1:$1/$3 > $2
}

initIncrFile(){
    cat > $MONITOR_ITEM_EXECUTOR <<end 
[{
    "id": 0,
    "insert": 0,
    "update": 0,
    "delete": 0,
    "ddl": 0,
    "unknown": 0,
    "error": 0,
    "insert_ns_top_3": [],
    "update_ns_top_3": [],
    "delete_ns_top_3": [],
    "ddl_ns_top_3": [],
    "unknown_ns_top_3": [],
    "error_ns_top_3": []
  }]
end
    cat > $MONITOR_ITEM_PERSIST <<end 
{
  "buffer_used": 0,
  "buffer_size": 0,
  "enable_disk_persist": false,
  "fetch_stage": "store memory and apply",
  "disk_write_count": 0,
  "disk_read_count": 0
}
end
    cat > $MONITOR_ITEM_REPL <<end 
{
  "logs_get": 0,
  "logs_repl": 0,
  "logs_success": 0,
  "tps": 0
}
end

}
initFullFile(){
    cat > $MONITOR_ITEM_PROGRESS <<end 
{
  "progress": "0.00%",
  "total_collection_number": 0,
  "finished_collection_number": 0,
  "processing_collection_number": 0,
  "wait_collection_number": 0
}
end
}

healthCheck(){
    log ">>>>> healthCheck begin <<<<<"
    if [ -f $BEING_HEALTH_CHECKED_FLAG ]; then 
        log "a health check is already running!"
        return 1
    fi

    if [ -f $IGNORE_HEALTH_CHECK_FLAG_FILE ]; then 
        log "healthCheck has been ignored!"
        return 0
    fi

    touch $BEING_HEALTH_CHECKED_FLAG

    local full_port=$(getItemFromFile full_sync.http_port $MONGOSHAKE_CONF)
    local incr_port=$(getItemFromFile incr_sync.http_port $MONGOSHAKE_CONF)
    if [ -z "$(getPidByNetstat $full_port)" ] && [ -z "$(getPidByNetstat $incr_port)" ] ; then
        log "port not listen, please check!"
        rm -f $BEING_HEALTH_CHECKED_FLAG
        return $ERR_PORT_NOT_LISTEN
    fi

    if [ -z getPidByPs ]; then
        log "mongoshake process not exist, please check!"
        rm -f $BEING_HEALTH_CHECKED_FLAG
        return $ERR_PROCESS_NOT_EXIST
    fi
    
    rm -f $BEING_HEALTH_CHECKED_FLAG
    log ">>>>> healthCheck end <<<<<"
    return 0
}

revive() {
    log ">>>>> revive begin <<<<<"
    if [ -f $BEING_REVIVED_FLAG ]; then 
        log "a revive process is already running!"
        return 1
    fi
    touch $BEING_REVIVED_FLAG
    local full_port=$(getItemFromFile full_sync.http_port $MONGOSHAKE_CONF)
    local incr_port=$(getItemFromFile incr_sync.http_port $MONGOSHAKE_CONF)
    if [ -z getPidByNetstat $full_port ] && [ -z getPidByNetstat $incr_port ] ; then
        reload
        rm -f $BEING_REVIVED_FLAG
        return 0
    fi

    if [ -z getPidByPs ]; then
        reload
        rm -f $BEING_REVIVED_FLAG
        return 0
    fi
    rm -f $BEING_REVIVED_FLAG
    log ">>>>> revive end <<<<<"
    return 0
}


getItemFromFile() {
    local res=$(cat $2 | sed '/^'$1'=/!d;s/^'$1'=//')
    echo "$res"
}

getPidByNetstat() {
    local pid=$(netstat -nultp | grep $1 | awk -F" "  '{print $7}' | awk -F"/" '{print $1}')
    echo "$pid"
}

getPidByPs() {
    local pid=$(ps aux | grep collector.linux | grep -v grep | awk -F" " '{print $2}')
    echo "$pid"
}