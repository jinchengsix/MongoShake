# showFcv
# desc: display feature compatibility version on web console
showFcv() {
  local jsstr="JSON.stringify(db.adminCommand({getParameter:1,featureCompatibilityVersion:1}))"
  local res=$(runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  res=$(echo "$res" | jq '.featureCompatibilityVersion.version' | sed 's/"//g')
  local tmpstr=$(cat <<EOF
{
  "labels": ["Feature compatibility version"],
  "data": [
    ["$res"]
  ]
}
EOF
  )
  echo "$tmpstr"
}

showNodeStatus() {
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status().members)" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  local hostinfo=($(echo "$tmpstr" | jq '.[].name'))
  local stateStr=($(echo "$tmpstr" | jq '.[].stateStr'))
  tmpstr=$(runMongoCmd "JSON.stringify(rs.conf().members)" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  local priority=($(echo "$tmpstr" | jq '.[].priority'))
  local hidden=($(echo "$tmpstr" | jq '.[].hidden'))
  local cnt=${#hostinfo[@]}
  local line
  tmpstr=''
  for((i=0;i<$cnt;i++)); do
    line="[${hostinfo[i]},${stateStr[i]},\"${priority[i]}\",\"${hidden[i]}\"]"
    tmpstr="$tmpstr,$line"
  done
  tmpstr=${tmpstr:1}
  tmpstr=$(cat <<EOF
{
  "labels": ["Host", "Node Role", "Priority", "Hidden"],
  "data": [
    $tmpstr
  ]
}
EOF
  )
  echo "$tmpstr"
}

showConnStr() {
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.isMaster().hosts)" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  tmpstr=$(echo "$tmpstr" | jq '.[]' | sed 's/"//g')
  tmpstr=$(echo $tmpstr | sed 's/ /,/g')
  tmpstr='mongodb://&lt;username&gt;:&lt;password&gt;@'$tmpstr'/?authSource=admin&replicaSet=foobar'
  tmpstr=$(cat <<EOF
{
  "labels": ["Connection string"],
  "data": [
    ["$tmpstr"]
  ]
}
EOF
  )
  echo "$tmpstr"
}

changeFcv() {
  if ! isMeMaster; then return 0; fi

  local jsstr="JSON.stringify(db.adminCommand({getParameter:1,featureCompatibilityVersion:1}))"
  local res=$(runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE))
  res=$(echo "$res" | jq '.featureCompatibilityVersion.version' | sed 's/"//g')

  local input=$(echo "$1" | jq '.fcv' | sed 's/"//g')
  if [ "$res" = "$input" ]; then return 0; fi

  local cnt=${#NODE_LIST[@]}
  if ! msIsReplStatusOk $cnt -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE); then return 0; fi

  jsstr="db.adminCommand({setFeatureCompatibilityVersion:\"$input\"})"
  runMongoCmd "$jsstr" -P $MY_PORT -u $DB_QC_USER -p $(cat $DB_QC_LOCAL_PASS_FILE)
}