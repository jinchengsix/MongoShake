#!/usr/bin/env bash
ERR_INVALID_PARAMS_MONGOCMD=201
OLD_BIN_PATH=/opt/mongodb/bin
NET_MAINTAIN_PORT=27099
MONGO_DB_PATH=/data/mongodb
RS_NAME=foobar
DB_QC_USER=qc_master
DB_QC_LOCAL_PASS_FILE=/data/pitrix.pwd
OLD_REPL_CFG_FILE=/data/upback34/replcfg
OLD_MONGOD_ENV_FILE=/data/upback34/mongod_env

command=$1
args="${@:2}"

isDev() {
  [ "$APPCTL_ENV" == "dev" ]
}

log() {
  if [ "$1" == "--debug" ]; then
    isDev || return 0
    shift
  fi
  logger -S 5000 -t appctl --id=$$ -- "[cmd=$command args='$args'] $@"
}

retry() {
  local tried=0
  local maxAttempts=$1
  local interval=$2
  local stopCodes=$3
  local cmd="${@:4}"
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
    $cmd && return 0 || {
      retCode=$?
      if [[ ",$stopCodes," == *",$retCode,"* ]]; then
        log "'$cmd' returned with stop code '$retCode'. Stopping ..."
        return $retCode
      fi
    }
    sleep $interval
    tried=$((tried+1))
  done

  log "'$cmd' still returned errors after $tried attempts. Stopping ..."
  return $retCode
}

runMongoCmd() {
  local cmd="/opt/mongodb/bin/mongo --quiet"
  local jsstr="$1"
  
  shift
  if [ $(($# % 2)) -ne 0 ]; then log "Invalid runMongoCmd params"; return $ERR_INVALID_PARAMS_MONGOCMD; fi
  while [ $# -gt 0 ]; do
    case $1 in
      "-u") cmd="$cmd --authenticationDatabase admin --username $2";;
      "-p") cmd="$cmd --password $2";;
      "-P") cmd="$cmd --port $2";;
      "-H") cmd="$cmd --host $2";;
    esac
    shift 2
  done

  timeout --preserve-status 5 $cmd --eval "$jsstr"
}

shellStartMongodForAdmin() {
  runuser mongodb -g mongodb -s "/bin/bash" -c "$OLD_BIN_PATH/mongod --port $NET_MAINTAIN_PORT --dbpath $MONGO_DB_PATH --logpath $MONGO_DB_PATH/mongod.log --fork"
}

shellStopMongodForAdmin() {
  runuser mongodb -g mongodb -s "/bin/bash" -c "$OLD_BIN_PATH/mongod --port $NET_MAINTAIN_PORT --dbpath $MONGO_DB_PATH --logpath $MONGO_DB_PATH/mongod.log --shutdown"
}

msGetHostDbVersion() {
  local jsstr=$(cat <<EOF
db.version()
EOF
  )
  runMongoCmd "$jsstr" $@
}

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
for(i=0; i<cnt; i++) {
  cfg.members[i].host=newlist[i]
  if (cfg.members[i].priority==0) {
    cfg.members[i].hidden=false
    cfg.members[i].priority=1
  }
}
mydb.system.replset.update({"_id":"$RS_NAME"},cfg)
EOF
  )
  runMongoCmd "$jsstr" -P $NET_MAINTAIN_PORT
}

getNodeList() {
  local tmpstr=$(cat $OLD_REPL_CFG_FILE | grep -o '"[[:digit:].]\+:[[:digit:]]\+"')
  local port=$(cat $OLD_MONGOD_ENV_FILE | sed -n '/^port/p' | grep -o '[[:digit:]]\+')
  echo $tmpstr | sed 's/:[0-9]\+/:'$port'/g' | sed 's/ /,/g'
}

rollback() {
  # stop mongod
  $OLD_BIN_PATH/stop-mongod-server.sh || :
  # disable auto revive
  mv $OLD_BIN_PATH/start-mongod-server.sh $OLD_BIN_PATH/start-mongod-server.sh.bak || :
  # start mongod in admin mode
  if ! shellStartMongodForAdmin; then
    echo "can not start mongod in admin mode"
    return 1
  fi
  retry 60 3 0 msGetHostDbVersion -P $NET_MAINTAIN_PORT
  # update qc_master's password
  if ! msModifyLocalSysUser; then
    echo "can not modify sys user's password"
    return 1
  fi
  # change listening port and priority
  if ! msUpdateReplCfgWhenUpgrade "$(getNodeList)"; then
    echo "can not update repl members' port and priority"
    return 1
  fi
  # stop mongod in admin mode
  if ! shellStopMongodForAdmin; then
    echo "can not stop mongod in admin mode"
    return 1
  fi
  # enable auto revive and start mongod in normal mode
  mv $OLD_BIN_PATH/start-mongod-server.sh.bak $OLD_BIN_PATH/start-mongod-server.sh || :
  $OLD_BIN_PATH/start-mongod-server.sh || :
}

execute() {
  local cmd=$1; log --debug "Executing command ..."
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  $cmd ${@:2}
}

set -eo pipefail
execute $command $args