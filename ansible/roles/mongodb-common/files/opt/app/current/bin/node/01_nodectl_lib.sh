# error code
ERR_PORT_NOT_LISTEN=500
ERR_PROCESS_NOT_EXIST=501

# path info
REPL_MONITOR_ITEM_FILE=/opt/app/current/bin/node/repl.monitor
IGNORE_HEALTH_CHECK_FLAG_FILE=/data/appctl/data/ignore_health.check.flag
MONGOSHAKE_CONF=/opt/app/current/conf/mongoshake/mongoshake.conf
BEING_HEALTH_CHECKED_FLAG=/data/appctl/data/being_health_checked.flag
BEING_REVIVED_FLAG=/data/appctl/data/being_revived.flag

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