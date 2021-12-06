APPCTL_CMD_PATH=/usr/bin/appctl
isSingleThread() {
  local tmpcnt=$(pgrep -fa "$APPCTL_CMD_PATH $1" | wc -l)
  test $tmpcnt -eq 2
}

isNodeFirstCreate() {
  test -f $NODE_FIRST_CREATE_FLAG_FILE
}


# msIsReplStatusOk
# check if replia set's status is ok
# 1 primary, other's secondary
msIsReplStatusOk() {
  local allcnt=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status())" $@ | jq .members[].stateStr)
  local pcnt=$(echo "$tmpstr" | grep PRIMARY | wc -l)
  local scnt=$(echo "$tmpstr" | grep SECONDARY | wc -l)
  test $pcnt -eq 1
  test $((pcnt+scnt)) -eq $allcnt
}

msIsReplOther() {
  local res=$(runMongoCmd "JSON.stringify(rs.status())" $@ | jq .ok)
  if [ -z "$res" ] || [ $res -eq 0 ]; then return 0; fi
  return 1
}

msIsHostMaster() {
  local hostinfo=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status().members)" $@)
  local state=$(echo $tmpstr | jq '.[] | select(.name=="'$hostinfo'") | .stateStr' | sed s/\"//g)
  test "$state" = "PRIMARY"
}

msIsHostSecondary() {
  local hostinfo=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status().members)" $@)
  local state=$(echo $tmpstr | jq '.[] | select(.name=="'$hostinfo'") | .stateStr' | sed s/\"//g)
  test "$state" = "SECONDARY"
}

msIsHostHidden() {
  local hostinfo=$1
  shift
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.conf().members)" $@)
  local pname=$(echo $tmpstr | jq '.[] | select(.hidden==true) | .host' | sed s/\"//g)
  test "$pname" = "$hostinfo"
}


isMeMaster() {
  msIsHostMaster "$MY_IP:$MY_PORT" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
}

isMeNotMaster() {
  ! msIsHostMaster "$MY_IP:$MY_PORT" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
}

msIsBalancerNotRunning() {
  local jsstr=$(cat <<EOF
if (sh.isBalancerRunning()) {
  quit(1)
}
else {
  quit(0)
}
EOF
  )

  runMongoCmd "$jsstr" $@
}

msIsBalancerOkForStop() {
  local jsstr=$(cat <<EOF
if (!sh.getBalancerState() && !sh.isBalancerRunning()) {
  quit(0)
}
else {
  quit(1)
}
EOF
  )

  runMongoCmd "$jsstr" $@
}
