monitor() {

}

healthCheck() {

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