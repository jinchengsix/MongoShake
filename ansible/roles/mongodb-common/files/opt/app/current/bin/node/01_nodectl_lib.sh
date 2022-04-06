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
    local title
    local value
    local port=$(getItemFromFile incr_sync.http_port $MONGOSHAKE_CONF)
    getMonitorItem $MONITOR_ITEM_EXECUTOR "executor"
    getMonitorItem $MONITOR_ITEM_PERSIST "persist"
    getMonitorItem $MONITOR_ITEM_QUEUE "queue"
    getMonitorItem $MONITOR_ITEM_REPL "repl"
    getMonitorItem $MONITOR_ITEM_SENTINEL "sentinel"
    getMonitorItem $MONITOR_ITEM_SENTINEL_OPTIONS "sentinel_options"
    getMonitorItem $MONITOR_ITEM_WORKER "worker"


    if [ ! -s $MONITOR_ITEM_EXECUTOR ]; then
        res=$(outputItem $MONITOR_ITEM_EXECUTOR "executor")
    fi


}

outputItem() {
    local group
    local title
    local value
    while read line; do
        group=$(echo $line | cut -d'/' -f1)
        title=$(echo $line | cut -d'/' -f2)
        if [ "$group" = "$2" ]; then
            if [ "$2" = "executor" ]; then
                
            else
                value=$(cat $1 |jq "$title")
            fi
        fi
        res="$res,\"$title\":$value"
    done < $1
    echo $res
}

getMonitorItem(){
    curl 127.0.0.1:$port/$2 > $1
}



healthCheck(){
    log ">>>>> healthCheck begin <<<<<"
    if [ -f isSingleThread $BEING_HEALTH_CHECKED_FLAG ]; then 
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
    if [ -z getPidByNetstat $full_port ] && [ -z getPidByNetstat $incr_port ] ; then
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
    if [ -f isSingleThread $BEING_REVIVED_FLAG ]; then 
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