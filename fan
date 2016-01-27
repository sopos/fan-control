#!/bin/bash
log() {
  date +"::[ ${2:-%T} ]:: $1" >&2
}
debug() {
  [[ -n "$DEBUG" ]] && log "$1" ' DEBUG  '
}

config=$(readlink -m $(dirname $0))/fan.conf
[[ -r $config ]] || config=/etc/fan.conf
log "using config file '$config'"

config_load() {
  log "loading config file '$config'"
  refresh=10
  renew=0
  watchdog=300
  fan_reset=auto
  fan=/proc/acpi/ibm/fan
  # temp_type=max|sum|mean
  temp_type='max'
  temp='echo "$(cat /sys/class/thermal/thermal_zone0/temp)/1000";
echo "$(cat /sys/class/thermal/thermal_zone1/temp)/1000"'
  table='
0 0 55
1 53 60
2 58 61
3 59 63
4 61 65
5 63 66
7 64 32767
'
  [[ -r $config ]] && bash -n $config && {
    . $config
    cat $config
  }
  trap "set_fan_level $fan_reset" EXIT
}

last_state=''
config_changed() {
  debug "check for config file change"
  local res=1
  [[ -r $config ]] || return $res
  local state=$(stat --printf '%Y %Z' $config)
  [[ "$state" != "$last_state" ]] && {
    log "config file has changed"
    res=0
  } || {
    debug "config file did not change"
  }
  last_state="$state"
  return $res
}

print_table() {
  echo "$table" | grep -v '^$'
}

set_fan_level() {
  debug "setting fan level to '$1'"
  echo "level $1" > $fan
}

get_fan_level() {
  debug "reading fan level"
  local x=`grep '^level:' $fan | sed -r 's/.*\s+(\S+)$/\1/'`
  echo "$x"
  debug "got '$x'"
}

get_modified_fan_level() {
  local level low high
  level="$1"
  if print_table | grep -q "^$level"; then
    :
  else
    log "current fan level '$level' is not defined in the table, reseting to table value"
    local current_temp=$(get_temp)
    while read level low high; do
      debug "$level $low $high"
      [[ $current_temp -lt $high ]] && break
    done < <(print_table)
  fi
  echo "$level"
  debug "modified fan level is '$level'"
}

get_temp() {
  debug "getting temperature"
  local max=0 sum=0 count=0 t
  while read t; do
    debug "$t"
    [[ $t -gt $max ]] && max=$t
    let sum+=$t
    let count++
  done < <(eval "$temp" | bc | sed -r 's/([^.]*).*$/\1/')
  mean=$(echo "scale=0; $sum/$count/1" | bc)
  debug "got max '$max', sum '$sum', mean '$mean'"
  case $temp_type in
    max)
      debug "returning temperature $max (max)"
      echo "$max"
    ;;
    sum)
      debug "returning temperature $sum (sum)"
      echo "$sum"
    ;;
    mean)
      debug "returning temperature $mean (mean)"
      echo "$mean"
    ;;
  esac
}

watchdog_timestamp() {
  [[ $(date +"%s") -ge $watchdog_next ]] && {
    log "keep alive stamp, current temperature is '$(get_temp)'"
    watchdog_next=$(($(date +"%s")+$watchdog))
  }
}

get_new_fan_level() {
  local current_temp=$1
  local current_fan_level=$2
  local modified_fan_level=$( get_modified_fan_level $current_fan_level )
  local row=( $( print_table | grep ^$modified_fan_level ) )
  local low=${row[1]}
  local high=${row[2]}
  local new_fan_level=$modified_fan_level
  [[ $current_temp -lt $low ]] && {
    log "temperature dropped below low value '$low', decreasing fan level"
    new_fan_level=$(print_table | grep -B 1 "^$current_fan_level" | head -n 1 | cut -d ' ' -f 1)
  }
  [[ $current_temp -gt $high ]] && {
    log "temperature exceeded high value '$high', increasing fan level"
    new_fan_level=$(print_table | grep -A 1 "^$current_fan_level" | tail -n 1 | cut -d ' ' -f 1)
  }
  echo $new_fan_level
}

config_changed 2>/dev/null
config_load
#first set
new_fan_level=$(get_modified_fan_level $(get_fan_level))

watchdog_timestamp

while :; do
  current_temp=$(get_temp)
  current_fan_level=$(get_fan_level)
  new_fan_level=$(get_new_fan_level $current_temp $current_fan_level)
  debug "new fan level is '$new_fan_level'"
  [[ "$current_fan_level" != "$new_fan_level" ]] && {
    log "setting fan level to '$new_fan_level'"
    set_fan_level $new_fan_level
  }
  i=$renew
  while :; do
    sleep $refresh
    watchdog_timestamp
    config_changed && {
      config_load
      break
    }
    [[ $i -eq 0 ]] && break
    let i--
    set_fan_level $new_fan_level
  done
done
