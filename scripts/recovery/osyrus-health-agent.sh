#!/usr/bin/env bash
set -euo pipefail
set +H
export PATH="/Users/nation/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Osyrus outage auto-remediation agent.
# - Ensures all VMs on vm1/vm2 are powered on
# - Verifies critical host reachability
# - Restarts observability stack when ports are unhealthy
# - Publishes capacity metrics (filesystems + ESXi datastores) for Grafana

LOG_FILE="${LOG_FILE:-$HOME/osyrus-health-agent.log}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

ESXI_USER="${ESXI_USER:-root}"
DEFAULT_ESXI_PASS='$PizzaBoy29$$'
ESXI_PASS="${ESXI_PASS:-$DEFAULT_ESXI_PASS}"
VM1_HOST="${VM1_HOST:-192.168.12.148}"
VM2_HOST="${VM2_HOST:-192.168.12.217}"

OBS_USER="${OBS_USER:-devops}"
OBS_PASS="${OBS_PASS:-RedAppleOne1*}"
OBS_HOST="${OBS_HOST:-192.168.12.245}"

NODE_EXPORTER_TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-$HOME/homebrew/var/node_exporter/textfile_collector}"
CAPACITY_METRICS_FILE="${CAPACITY_METRICS_FILE:-$NODE_EXPORTER_TEXTFILE_DIR/osyrus_capacity.prom}"
SPARK_IMAGE_METRICS_SCRIPT="${SPARK_IMAGE_METRICS_SCRIPT:-$HOME/Documents/New project/osyrus-portal/scripts/recovery/collect_spark_image_metrics.py}"
PUBLIC_CHAT_VRRP_METRICS_SCRIPT="${PUBLIC_CHAT_VRRP_METRICS_SCRIPT:-$HOME/Documents/New project/osyrus-portal/scripts/recovery/collect_public_chat_vrrp_metrics.py}"
WEB_HA_METRICS_SCRIPT="${WEB_HA_METRICS_SCRIPT:-$HOME/Documents/New project/osyrus-portal/scripts/recovery/collect_web_ha_metrics.py}"
NETFLOW_DIR="${NETFLOW_DIR:-$HOME/.osyrus/netflow/ex4200}"
NETFLOW_SWITCH_NAME="${NETFLOW_SWITCH_NAME:-osyrus-switch-ex4200-01}"
NETFLOW_SWITCH_IP="${NETFLOW_SWITCH_IP:-192.168.1.221}"
NETFLOW_FILES_TO_SCAN="${NETFLOW_FILES_TO_SCAN:-15}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-60}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"
DISK_CRITICAL_PERCENT="${DISK_CRITICAL_PERCENT:-95}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-4}"

CRITICAL_IPS=(
  "192.168.12.1"
  "192.168.12.136"
  "192.168.12.137"
  "192.168.12.148"
  "192.168.12.217"
  "192.168.1.221"
  "192.168.1.12"
  "192.168.1.93"
  "192.168.12.1"
  "192.168.12.89"
  "192.168.12.96"
  "192.168.12.161"
  "192.168.12.162"
  "192.168.12.170"
  "192.168.12.171"
  "192.168.12.172"
  "192.168.12.173"
  "192.168.12.174"
  "192.168.12.240"
  "192.168.12.241"
  "192.168.12.242"
  "192.168.12.243"
  "192.168.12.244"
  "192.168.12.245"
  "192.168.12.246"
  "192.168.12.251"
  "192.168.12.252"
)

DISK_SSH_TARGETS=(
  'osyrus-fw01|192.168.12.1|perknation|$PizzaBoy29$$'
  'RedApple2|192.168.12.89|redapple2|Fermin!Rivera2023'
  'redapple4|192.168.12.96|redapple4|Fermin!Rivera2023'
  'infra-dns-ntp-01|192.168.12.136|devops|RedAppleOne1*'
  'redapple3|192.168.1.12|redapple|Fermin!Rivera2023'
  'ubuntu24-zt-01|192.168.1.93|devops|RedAppleOne1*'
  'neonflux-chat-vm1|192.168.12.161|neonflux|RedAppleOne1*'
  'neonflux-chat-vm2|192.168.12.162|neonflux|RedAppleOne1*'
  'mac-spark-storage|192.168.12.170|devops|U5KOGMavSQ7o1QS7i00ztW0iub1hO94m'
  'mac-spark-storage-backup|192.168.12.171|devops|4ea31dbb659262387be0b56cdbb3721c26b4'
  'neonflux-postgres-01|192.168.12.172|devops|SSH_KEY:/Users/nation/.ssh/osyrus_ops'
  'chewbacuh|192.168.12.173|devops|RedAppleOne1*'
  'lil-beastly|192.168.12.174|devops|RedAppleOne1*'
  'osyrus-scan-01|192.168.12.240|devops|RedAppleOne1*'
  'osyrus-wazuh-01|192.168.12.241|devops|RedAppleOne1*'
  'osyrus-opensearch-01|192.168.12.242|devops|RedAppleOne1*'
  'osyrus-shuffle-01|192.168.12.243|devops|RedAppleOne1*'
  'osyrus-ansible-01|192.168.12.244|devops|RedAppleOne1*'
  'osyrus-observability-01|192.168.12.245|devops|RedAppleOne1*'
  'osyrus-cyberlab-01|192.168.12.246|devops|RedAppleOne1*'
  'sparkbox|192.168.12.251|perknation|$PizzaBoy29$$'
)

JUNOS_SWITCH_TARGETS=(
  'osyrus-switch-ex4200-01|192.168.1.221|perknation|$PizzaBoy29$$'
)

SSH_COMMON_OPTS=(
  -o StrictHostKeyChecking=no
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=1
)

log() {
  local msg="$1"
  printf '%s run=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$msg" | tee -a "$LOG_FILE"
}

need_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    log "ERROR missing_command=$c"
    return 1
  fi
}

can_ping() {
  local ip="$1"
  ping -c 1 -W 700 "$ip" >/dev/null 2>&1
}

can_port() {
  local ip="$1"
  local port="$2"
  nc -zvw1 "$ip" "$port" >/dev/null 2>&1
}

escape_prom_label() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/ }"
  printf '%s' "$raw"
}

emit_metric() {
  local file="$1"
  local name="$2"
  local value="$3"
  shift 3

  local line="$name"
  local first=1
  local kv key val
  if [[ "$#" -gt 0 ]]; then
    line+="{"
    for kv in "$@"; do
      key="${kv%%=*}"
      val="${kv#*=}"
      val="$(escape_prom_label "$val")"
      if [[ "$first" -eq 1 ]]; then
        first=0
      else
        line+=","
      fi
      line+="${key}=\"${val}\""
    done
    line+="}"
  fi
  printf '%s %s\n' "$line" "$value" >>"$file"
}

ssh_run() {
  local user="$1"
  local pass="$2"
  local host="$3"
  local cmd="$4"
  if [[ "$pass" == SSH_KEY:* ]]; then
    local key_path="${pass#SSH_KEY:}"
    ssh -i "$key_path" "${SSH_COMMON_OPTS[@]}" "$user@$host" "$cmd"
  else
    sshpass -p "$pass" ssh "${SSH_COMMON_OPTS[@]}" "$user@$host" "$cmd"
  fi
}

govc_login() {
  local host="$1"
  export GOVC_URL="$host"
  export GOVC_USERNAME="$ESXI_USER"
  export GOVC_PASSWORD="$ESXI_PASS"
  export GOVC_INSECURE=1
  govc about >/dev/null 2>&1
}

ensure_host_vms_on() {
  local host="$1"
  if ! govc_login "$host"; then
    log "ERROR esxi_login_failed host=$host user=$ESXI_USER"
    return 1
  fi

  local vm_path info_json vm_name power_state is_template
  while IFS= read -r vm_path; do
    [[ -z "$vm_path" ]] && continue
    info_json="$(govc vm.info -json "$vm_path" 2>/dev/null || true)"
    [[ -z "$info_json" ]] && {
      log "WARN vm_info_failed host=$host path=$vm_path"
      continue
    }

    vm_name="$(jq -r '.virtualMachines[0].name // empty' <<<"$info_json")"
    power_state="$(jq -r '.virtualMachines[0].runtime.powerState // "unknown"' <<<"$info_json")"
    is_template="$(jq -r '.virtualMachines[0].config.template // false' <<<"$info_json")"

    if [[ "$is_template" == "true" ]]; then
      continue
    fi

    if [[ "$power_state" == "poweredOff" ]]; then
      if govc vm.power -on "$vm_path" >/tmp/osyrus-agent-power.$$ 2>&1; then
        log "REMEDIATE vm_power_on host=$host vm=$vm_name"
      else
        log "ERROR vm_power_on_failed host=$host vm=$vm_name details=$(tr '\n' ' ' </tmp/osyrus-agent-power.$$)"
      fi
      rm -f /tmp/osyrus-agent-power.$$
    fi
  done < <(govc find /ha-datacenter/vm -type m)

  return 0
}

ensure_observability_stack() {
  # If observability VM is up but key ports are missing, restart stack.
  if ! can_ping "$OBS_HOST"; then
    log "WARN observability_ping_down host=$OBS_HOST"
    return 0
  fi

  local grafana_ok prom_ok loki_ok
  grafana_ok=1
  prom_ok=1
  loki_ok=1

  can_port "$OBS_HOST" 3000 || grafana_ok=0
  can_port "$OBS_HOST" 9090 || prom_ok=0
  can_port "$OBS_HOST" 3100 || loki_ok=0

  if [[ "$grafana_ok" -eq 1 && "$prom_ok" -eq 1 && "$loki_ok" -eq 1 ]]; then
    return 0
  fi

  log "REMEDIATE observability_restart host=$OBS_HOST ports_healthy=3000:$grafana_ok,9090:$prom_ok,3100:$loki_ok"
  sshpass -p "$OBS_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$OBS_USER@$OBS_HOST" \
    "printf '$OBS_PASS\n' | sudo -S docker compose -f /opt/observability/docker-compose.yml up -d" >/tmp/osyrus-agent-observability.$$ 2>&1 || {
      log "ERROR observability_restart_failed host=$OBS_HOST details=$(tr '\n' ' ' </tmp/osyrus-agent-observability.$$)"
      rm -f /tmp/osyrus-agent-observability.$$
      return 1
    }
  rm -f /tmp/osyrus-agent-observability.$$
}

critical_reachability_summary() {
  local up=0
  local down=0
  local ip
  for ip in "${CRITICAL_IPS[@]}"; do
    if can_ping "$ip"; then
      up=$((up + 1))
      log "HEALTH host=$ip ping=UP"
    else
      down=$((down + 1))
      log "HEALTH host=$ip ping=DOWN"
    fi
  done
  log "SUMMARY critical_up=$up critical_down=$down"
}

collect_remote_disk_metrics() {
  local metrics_file="$1"
  local host_name="$2"
  local host_ip="$3"
  local host_user="$4"
  local host_pass="$5"

  local df_out
  df_out="$(ssh_run "$host_user" "$host_pass" "$host_ip" "df -PTB1 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\",\$6); print \$1\"\\t\"\$2\"\\t\"\$3\"\\t\"\$4\"\\t\"\$5\"\\t\"\$6\"\\t\"\$7}'" 2>/dev/null || true)"
  if [[ -z "$df_out" ]]; then
    emit_metric "$metrics_file" "osyrus_remote_filesystem_collection_success" "0" "host=$host_name" "ip=$host_ip"
    log "WARN disk_collection_failed host=$host_name ip=$host_ip"
    return 0
  fi
  emit_metric "$metrics_file" "osyrus_remote_filesystem_collection_success" "1" "host=$host_name" "ip=$host_ip"

  local root_pct=0
  local root_found=0
  local device fstype size used avail pct mount
  while IFS=$'\t' read -r device fstype size used avail pct mount; do
    [[ -z "${mount:-}" ]] && continue
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    [[ "$avail" =~ ^[0-9]+$ ]] || avail=0
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0

    emit_metric "$metrics_file" "osyrus_remote_filesystem_size_bytes" "$size" \
      "host=$host_name" "ip=$host_ip" "device=$device" "fstype=$fstype" "mountpoint=$mount"
    emit_metric "$metrics_file" "osyrus_remote_filesystem_used_bytes" "$used" \
      "host=$host_name" "ip=$host_ip" "device=$device" "fstype=$fstype" "mountpoint=$mount"
    emit_metric "$metrics_file" "osyrus_remote_filesystem_avail_bytes" "$avail" \
      "host=$host_name" "ip=$host_ip" "device=$device" "fstype=$fstype" "mountpoint=$mount"
    emit_metric "$metrics_file" "osyrus_remote_filesystem_used_percent" "$pct" \
      "host=$host_name" "ip=$host_ip" "device=$device" "fstype=$fstype" "mountpoint=$mount"

    if [[ "$mount" == "/" ]]; then
      root_pct="$pct"
      root_found=1
    fi
  done <<<"$df_out"

  if [[ "$root_found" -eq 1 ]]; then
    emit_metric "$metrics_file" "osyrus_remote_root_used_percent" "$root_pct" "host=$host_name" "ip=$host_ip"
    if [[ "$root_pct" -ge "$DISK_CRITICAL_PERCENT" ]]; then
      log "WARN disk_pressure_critical host=$host_name ip=$host_ip root_used_percent=$root_pct"
    elif [[ "$root_pct" -ge "$DISK_WARN_PERCENT" ]]; then
      log "WARN disk_pressure_warn host=$host_name ip=$host_ip root_used_percent=$root_pct"
    fi
  fi

  local old_stats old_count old_bytes
  old_stats="$(ssh_run "$host_user" "$host_pass" "$host_ip" "find /var/log -xdev -type f -mtime +${LOG_RETENTION_DAYS} -printf '%s\n' 2>/dev/null | awk '{count+=1;sum+=\$1} END {printf \"%d\\t%.0f\", count+0, sum+0}'" 2>/dev/null || true)"
  old_count="${old_stats%%$'\t'*}"
  old_bytes="${old_stats##*$'\t'}"
  [[ "$old_count" =~ ^[0-9]+$ ]] || old_count=0
  [[ "$old_bytes" =~ ^[0-9]+$ ]] || old_bytes=0
  emit_metric "$metrics_file" "osyrus_remote_log_files_older_than_days" "$old_count" \
    "host=$host_name" "ip=$host_ip" "days=$LOG_RETENTION_DAYS"
  emit_metric "$metrics_file" "osyrus_remote_log_bytes_older_than_days" "$old_bytes" \
    "host=$host_name" "ip=$host_ip" "days=$LOG_RETENTION_DAYS"

  local var_log_bytes
  var_log_bytes="$(ssh_run "$host_user" "$host_pass" "$host_ip" "du -sxB1 /var/log 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
  [[ "$var_log_bytes" =~ ^[0-9]+$ ]] || var_log_bytes=0
  emit_metric "$metrics_file" "osyrus_remote_var_log_size_bytes" "$var_log_bytes" "host=$host_name" "ip=$host_ip"
}

collect_esxi_datastore_metrics() {
  local metrics_file="$1"
  local esxi_host="$2"

  if ! govc_login "$esxi_host"; then
    emit_metric "$metrics_file" "osyrus_esxi_datastore_collection_success" "0" "esxi_host=$esxi_host"
    log "WARN datastore_collection_failed esxi_host=$esxi_host"
    return 0
  fi

  local ds_rows
  ds_rows="$(govc datastore.info -json 2>/dev/null | jq -r '.datastores[] | [(.summary.name // "unknown"), (.summary.capacity // 0), (.summary.freeSpace // 0), (.summary.uncommitted // 0), (.summary.type // "unknown")] | @tsv' 2>/dev/null || true)"
  if [[ -z "$ds_rows" ]]; then
    emit_metric "$metrics_file" "osyrus_esxi_datastore_collection_success" "0" "esxi_host=$esxi_host"
    log "WARN datastore_collection_empty esxi_host=$esxi_host"
    return 0
  fi

  emit_metric "$metrics_file" "osyrus_esxi_datastore_collection_success" "1" "esxi_host=$esxi_host"

  local ds_name capacity free_space uncommitted ds_type used_space used_pct
  while IFS=$'\t' read -r ds_name capacity free_space uncommitted ds_type; do
    [[ "$capacity" =~ ^[0-9]+$ ]] || capacity=0
    [[ "$free_space" =~ ^[0-9]+$ ]] || free_space=0
    [[ "$uncommitted" =~ ^[0-9]+$ ]] || uncommitted=0
    used_space=$((capacity - free_space))
    if [[ "$capacity" -gt 0 ]]; then
      used_pct="$(awk -v used="$used_space" -v cap="$capacity" 'BEGIN {printf "%.2f", (used*100)/cap}')"
    else
      used_pct="0"
    fi

    emit_metric "$metrics_file" "osyrus_esxi_datastore_capacity_bytes" "$capacity" \
      "esxi_host=$esxi_host" "datastore=$ds_name" "datastore_type=$ds_type"
    emit_metric "$metrics_file" "osyrus_esxi_datastore_free_bytes" "$free_space" \
      "esxi_host=$esxi_host" "datastore=$ds_name" "datastore_type=$ds_type"
    emit_metric "$metrics_file" "osyrus_esxi_datastore_used_bytes" "$used_space" \
      "esxi_host=$esxi_host" "datastore=$ds_name" "datastore_type=$ds_type"
    emit_metric "$metrics_file" "osyrus_esxi_datastore_uncommitted_bytes" "$uncommitted" \
      "esxi_host=$esxi_host" "datastore=$ds_name" "datastore_type=$ds_type"
    emit_metric "$metrics_file" "osyrus_esxi_datastore_used_percent" "$used_pct" \
      "esxi_host=$esxi_host" "datastore=$ds_name" "datastore_type=$ds_type"
  done <<<"$ds_rows"
}

collect_esxi_host_resource_metrics() {
  local metrics_file="$1"
  local esxi_host="$2"

  if ! govc_login "$esxi_host"; then
    emit_metric "$metrics_file" "osyrus_esxi_host_collection_success" "0" "esxi_host=$esxi_host"
    log "WARN esxi_host_metrics_failed esxi_host=$esxi_host reason=login_failed"
    return 0
  fi

  local host_row
  host_row="$(govc host.info -json 2>/dev/null | jq -r '.hostSystems[0] | [(.name // "unknown"), (.summary.hardware.numCpuCores // 0), (.summary.hardware.cpuMhz // 0), (.summary.quickStats.overallCpuUsage // 0), (.summary.hardware.memorySize // 0), (.summary.quickStats.overallMemoryUsage // 0), (.summary.hardware.vendor // "unknown"), (.summary.hardware.model // "unknown")] | @tsv' 2>/dev/null || true)"
  if [[ -z "$host_row" || "$host_row" == "null" ]]; then
    emit_metric "$metrics_file" "osyrus_esxi_host_collection_success" "0" "esxi_host=$esxi_host"
    log "WARN esxi_host_metrics_failed esxi_host=$esxi_host reason=empty_payload"
    return 0
  fi

  emit_metric "$metrics_file" "osyrus_esxi_host_collection_success" "1" "esxi_host=$esxi_host"

  local esxi_name cpu_cores cpu_mhz cpu_used_mhz mem_total_bytes mem_used_mb vendor model
  IFS=$'\t' read -r esxi_name cpu_cores cpu_mhz cpu_used_mhz mem_total_bytes mem_used_mb vendor model <<<"$host_row"
  [[ "$cpu_cores" =~ ^[0-9]+$ ]] || cpu_cores=0
  [[ "$cpu_mhz" =~ ^[0-9]+$ ]] || cpu_mhz=0
  [[ "$cpu_used_mhz" =~ ^[0-9]+$ ]] || cpu_used_mhz=0
  [[ "$mem_total_bytes" =~ ^[0-9]+$ ]] || mem_total_bytes=0
  [[ "$mem_used_mb" =~ ^[0-9]+$ ]] || mem_used_mb=0

  local cpu_capacity_mhz cpu_used_pct mem_used_bytes mem_free_bytes mem_used_pct
  cpu_capacity_mhz=$((cpu_cores * cpu_mhz))
  if [[ "$cpu_capacity_mhz" -gt 0 ]]; then
    cpu_used_pct="$(awk -v used="$cpu_used_mhz" -v cap="$cpu_capacity_mhz" 'BEGIN {printf "%.2f", (used*100)/cap}')"
  else
    cpu_used_pct="0"
  fi

  mem_used_bytes=$((mem_used_mb * 1024 * 1024))
  mem_free_bytes=$((mem_total_bytes - mem_used_bytes))
  if [[ "$mem_free_bytes" -lt 0 ]]; then
    mem_free_bytes=0
  fi
  if [[ "$mem_total_bytes" -gt 0 ]]; then
    mem_used_pct="$(awk -v used="$mem_used_bytes" -v total="$mem_total_bytes" 'BEGIN {printf "%.2f", (used*100)/total}')"
  else
    mem_used_pct="0"
  fi

  emit_metric "$metrics_file" "osyrus_esxi_host_cpu_capacity_mhz" "$cpu_capacity_mhz" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
  emit_metric "$metrics_file" "osyrus_esxi_host_cpu_used_mhz" "$cpu_used_mhz" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
  emit_metric "$metrics_file" "osyrus_esxi_host_cpu_used_percent" "$cpu_used_pct" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
  emit_metric "$metrics_file" "osyrus_esxi_host_memory_total_bytes" "$mem_total_bytes" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
  emit_metric "$metrics_file" "osyrus_esxi_host_memory_used_bytes" "$mem_used_bytes" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
  emit_metric "$metrics_file" "osyrus_esxi_host_memory_free_bytes" "$mem_free_bytes" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
  emit_metric "$metrics_file" "osyrus_esxi_host_memory_used_percent" "$mem_used_pct" \
    "esxi_host=$esxi_host" "esxi_name=$esxi_name" "vendor=$vendor" "model=$model"
}

collect_junos_switch_metrics() {
  local metrics_file="$1"
  local switch_name="$2"
  local switch_ip="$3"
  local switch_user="$4"
  local switch_pass="$5"

  local terse_out stats_out mac_out arp_out sys_alarm_out chassis_alarm_out netflow_cfg_out sflow_cfg_out
  terse_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show interfaces terse | no-more" 2>/dev/null || true)"
  stats_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show interfaces statistics ge-* | no-more" 2>/dev/null || true)"
  mac_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show ethernet-switching table brief | no-more" 2>/dev/null || true)"
  arp_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show arp no-resolve | no-more" 2>/dev/null || true)"
  sys_alarm_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show system alarms | no-more" 2>/dev/null || true)"
  chassis_alarm_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show chassis alarms | no-more" 2>/dev/null || true)"
  netflow_cfg_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show configuration forwarding-options | display set | no-more" 2>/dev/null || true)"
  sflow_cfg_out="$(ssh_run "$switch_user" "$switch_pass" "$switch_ip" "show configuration protocols sflow | display set | no-more" 2>/dev/null || true)"

  if [[ -z "$terse_out" || -z "$stats_out" ]]; then
    emit_metric "$metrics_file" "osyrus_switch_collection_success" "0" "switch_name=$switch_name" "switch_ip=$switch_ip"
    log "WARN switch_metrics_failed switch=$switch_name ip=$switch_ip"
    return 0
  fi

  emit_metric "$metrics_file" "osyrus_switch_collection_success" "1" "switch_name=$switch_name" "switch_ip=$switch_ip"

  local tmp_port_state tmp_port_stats tmp_mac_table tmp_mac_count tmp_arp_table tmp_ip_by_port
  tmp_port_state="/tmp/osyrus-switch-port-state.$$.tsv"
  tmp_port_stats="/tmp/osyrus-switch-port-stats.$$.tsv"
  tmp_mac_table="/tmp/osyrus-switch-mac-table.$$.tsv"
  tmp_mac_count="/tmp/osyrus-switch-mac-count.$$.tsv"
  tmp_arp_table="/tmp/osyrus-switch-arp-table.$$.tsv"
  tmp_ip_by_port="/tmp/osyrus-switch-ip-by-port.$$.tsv"

  printf '%s\n' "$terse_out" | awk '
    $1 ~ /^ge-[0-9]+\/[0-9]+\/[0-9]+$/ {
      admin = ($2 == "up") ? 1 : 0
      link = ($3 == "up") ? 1 : 0
      print $1 "\t" admin "\t" link
    }
  ' >"$tmp_port_state"

  printf '%s\n' "$stats_out" | awk '
    function flush() {
      if (iface != "") {
        print iface "\t" link_up "\t" in_bps "\t" in_pps "\t" out_bps "\t" out_pps "\t" in_err "\t" out_err "\t" mac
      }
    }
    /^Physical interface: ge-[0-9]+\/[0-9]+\/[0-9]+,/ {
      flush()
      iface = $3
      sub(/,$/, "", iface)
      link_up = (tolower($NF) == "up") ? 1 : 0
      in_bps = 0
      in_pps = 0
      out_bps = 0
      out_pps = 0
      in_err = 0
      out_err = 0
      mac = "unknown"
      next
    }
    /^  Current address:/ {
      mac = $3
      sub(/,$/, "", mac)
      next
    }
    /^  Input rate/ {
      in_bps = $4
      in_pps = $6
      gsub(/[^0-9]/, "", in_bps)
      gsub(/[^0-9]/, "", in_pps)
      next
    }
    /^  Output rate/ {
      out_bps = $4
      out_pps = $6
      gsub(/[^0-9]/, "", out_bps)
      gsub(/[^0-9]/, "", out_pps)
      next
    }
    /^  Input errors:/ {
      in_err = $3
      out_err = $6
      gsub(/[^0-9]/, "", in_err)
      gsub(/[^0-9]/, "", out_err)
      next
    }
    END { flush() }
  ' >"$tmp_port_stats"

  printf '%s\n' "$mac_out" | awk '
    tolower($2) ~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/ && $3 == "Learn" && $5 ~ /^ge-[0-9]+\/[0-9]+\/[0-9]+\.0$/ {
      iface = $5
      sub(/\.0$/, "", iface)
      print tolower($2) "\t" iface
    }
  ' >"$tmp_mac_table"

  awk -F'\t' '{count[$2]++} END {for (iface in count) print iface "\t" count[iface]}' "$tmp_mac_table" >"$tmp_mac_count"

  printf '%s\n' "$arp_out" | awk '
    tolower($1) ~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/ {
      print tolower($1) "\t" $2
    }
  ' >"$tmp_arp_table"

  awk -F'\t' '
    FNR == NR { ip[$1] = $2; next }
    {
      if (ip[$1] != "") {
        print $2 "\t" $1 "\t" ip[$1]
      }
    }
  ' "$tmp_arp_table" "$tmp_mac_table" >"$tmp_ip_by_port"

  local total_ports up_ports error_ports
  total_ports="$(wc -l <"$tmp_port_state" | tr -d ' ')"
  up_ports="$(awk -F'\t' '$3 == 1 {c++} END {print c+0}' "$tmp_port_state")"
  error_ports="$(awk -F'\t' '($7 + $8) > 0 {c++} END {print c+0}' "$tmp_port_stats")"

  local sys_alarm_total chassis_alarm_total sys_major sys_minor chassis_major chassis_minor
  sys_alarm_total="$(printf '%s\n' "$sys_alarm_out" | awk '/^[0-9]+ alarms currently active/{print $1; exit}')"
  chassis_alarm_total="$(printf '%s\n' "$chassis_alarm_out" | awk '/^[0-9]+ alarms currently active/{print $1; exit}')"
  [[ "$sys_alarm_total" =~ ^[0-9]+$ ]] || sys_alarm_total=0
  [[ "$chassis_alarm_total" =~ ^[0-9]+$ ]] || chassis_alarm_total=0
  sys_major="$(printf '%s\n' "$sys_alarm_out" | awk '$3 == "Major" {c++} END {print c+0}')"
  sys_minor="$(printf '%s\n' "$sys_alarm_out" | awk '$3 == "Minor" {c++} END {print c+0}')"
  chassis_major="$(printf '%s\n' "$chassis_alarm_out" | awk '$3 == "Major" {c++} END {print c+0}')"
  chassis_minor="$(printf '%s\n' "$chassis_alarm_out" | awk '$3 == "Minor" {c++} END {print c+0}')"

  local netflow_enabled sflow_enabled
  if printf '%s\n' "$netflow_cfg_out" | grep -Eq 'sampling|flow-server|inline-jflow'; then
    netflow_enabled=1
  else
    netflow_enabled=0
  fi
  if printf '%s\n' "$sflow_cfg_out" | grep -Eq '^set protocols sflow'; then
    sflow_enabled=1
  else
    sflow_enabled=0
  fi

  local circuit_health
  circuit_health="$(awk -v total="$total_ports" -v up="$up_ports" -v err="$error_ports" -v maj="$((sys_major + chassis_major))" -v min="$((sys_minor + chassis_minor))" '
    BEGIN {
      if (total > 0) {
        score = (up * 100) / total
      } else {
        score = 0
      }
      score = score - (err * 2) - (maj * 15) - (min * 5)
      if (score < 0) score = 0
      if (score > 100) score = 100
      printf "%.2f", score
    }
  ')"

  emit_metric "$metrics_file" "osyrus_switch_ports_total" "$total_ports" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_ports_up" "$up_ports" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_port_error_interfaces" "$error_ports" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_system_alarms_total" "$sys_alarm_total" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_chassis_alarms_total" "$chassis_alarm_total" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_netflow_enabled" "$netflow_enabled" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_sflow_enabled" "$sflow_enabled" "switch_name=$switch_name" "switch_ip=$switch_ip"
  emit_metric "$metrics_file" "osyrus_switch_circuit_health_score" "$circuit_health" "switch_name=$switch_name" "switch_ip=$switch_ip"

  local iface admin_up link_up mac_count
  while IFS=$'\t' read -r iface admin_up link_up; do
    [[ -z "${iface:-}" ]] && continue
    mac_count="$(awk -F'\t' -v p="$iface" '$1 == p {print $2; exit}' "$tmp_mac_count")"
    [[ "$mac_count" =~ ^[0-9]+$ ]] || mac_count=0
    emit_metric "$metrics_file" "osyrus_switch_port_admin_up" "$admin_up" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_link_up" "$link_up" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_mac_learned_count" "$mac_count" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
  done <"$tmp_port_state"

  local stat_link in_bps in_pps out_bps out_pps in_err out_err mac
  while IFS=$'\t' read -r iface stat_link in_bps in_pps out_bps out_pps in_err out_err mac; do
    [[ -z "${iface:-}" ]] && continue
    emit_metric "$metrics_file" "osyrus_switch_port_input_bps" "$in_bps" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_output_bps" "$out_bps" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_input_pps" "$in_pps" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_output_pps" "$out_pps" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_input_errors" "$in_err" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_output_errors" "$out_err" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface"
    emit_metric "$metrics_file" "osyrus_switch_port_interface_mac_info" "1" "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$iface" "interface_mac=$mac"
  done <"$tmp_port_stats"

  local observed_port observed_mac observed_ip
  while IFS=$'\t' read -r observed_port observed_mac observed_ip; do
    [[ -z "${observed_port:-}" ]] && continue
    emit_metric "$metrics_file" "osyrus_switch_port_observed_client" "1" \
      "switch_name=$switch_name" "switch_ip=$switch_ip" "port=$observed_port" "client_mac=$observed_mac" "client_ip=$observed_ip"
  done <"$tmp_ip_by_port"

  rm -f "$tmp_port_state" "$tmp_port_stats" "$tmp_mac_table" "$tmp_mac_count" "$tmp_arp_table" "$tmp_ip_by_port"
}

collect_netflow_metrics() {
  local metrics_file="$1"

  if ! command -v nfdump >/dev/null 2>&1; then
    emit_metric "$metrics_file" "osyrus_netflow_collection_success" "0" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
    log "WARN netflow_collection_failed reason=missing_nfdump"
    return 0
  fi

  if [[ ! -d "$NETFLOW_DIR" ]]; then
    emit_metric "$metrics_file" "osyrus_netflow_collection_success" "0" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
    log "WARN netflow_collection_failed reason=missing_dir dir=$NETFLOW_DIR"
    return 0
  fi

  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$NETFLOW_DIR" -maxdepth 1 -type f -name "nfcapd.[0-9]*" 2>/dev/null | LC_ALL=C sort | tail -n "$NETFLOW_FILES_TO_SCAN")

  if [[ "${#files[@]}" -eq 0 ]]; then
    emit_metric "$metrics_file" "osyrus_netflow_collection_success" "0" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
    log "WARN netflow_collection_failed reason=no_flow_files dir=$NETFLOW_DIR"
    return 0
  fi

  local first_file last_file range_path summary
  first_file="${files[0]}"
  last_file="${files[${#files[@]}-1]}"
  range_path="$(dirname "$first_file")/$(basename "$first_file"):$(basename "$last_file")"
  summary="$(nfdump -R "$range_path" -I 2>/dev/null || true)"
  if [[ -z "$summary" ]]; then
    emit_metric "$metrics_file" "osyrus_netflow_collection_success" "0" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
    log "WARN netflow_collection_failed reason=empty_summary range=$range_path"
    return 0
  fi

  emit_metric "$metrics_file" "osyrus_netflow_collection_success" "1" \
    "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"

  local flows_total packets_total bytes_total seq_failures
  flows_total="$(printf '%s\n' "$summary" | awk -F': ' '$1=="Flows" {print $2; exit}')"
  packets_total="$(printf '%s\n' "$summary" | awk -F': ' '$1=="Packets" {print $2; exit}')"
  bytes_total="$(printf '%s\n' "$summary" | awk -F': ' '$1=="Bytes" {print $2; exit}')"
  seq_failures="$(printf '%s\n' "$summary" | awk -F': ' '$1=="Sequence failures" {print $2; exit}')"
  [[ "$flows_total" =~ ^[0-9]+$ ]] || flows_total=0
  [[ "$packets_total" =~ ^[0-9]+$ ]] || packets_total=0
  [[ "$bytes_total" =~ ^[0-9]+$ ]] || bytes_total=0
  [[ "$seq_failures" =~ ^[0-9]+$ ]] || seq_failures=0

  emit_metric "$metrics_file" "osyrus_netflow_flows_total" "$flows_total" \
    "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
  emit_metric "$metrics_file" "osyrus_netflow_packets_total" "$packets_total" \
    "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
  emit_metric "$metrics_file" "osyrus_netflow_bytes_total" "$bytes_total" \
    "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"
  emit_metric "$metrics_file" "osyrus_netflow_sequence_failures_total" "$seq_failures" \
    "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP"

  local top_src top_dst top_proto rank ip bytes packets proto
  top_src="$(nfdump -R "$range_path" -o csv -s srcip/bytes -n 5 -q 2>/dev/null || true)"
  rank=0
  while IFS=',' read -r _ _ _ _ ip _ _ packets _ bytes _ _ _ _; do
    [[ "$ip" == "val" ]] && continue
    [[ -z "$ip" || "$ip" == "No matching flows" ]] && continue
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    [[ "$packets" =~ ^[0-9]+$ ]] || packets=0
    rank=$((rank + 1))
    emit_metric "$metrics_file" "osyrus_netflow_top_src_bytes" "$bytes" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP" "rank=$rank" "src_ip=$ip"
    emit_metric "$metrics_file" "osyrus_netflow_top_src_packets" "$packets" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP" "rank=$rank" "src_ip=$ip"
  done <<<"$top_src"

  top_dst="$(nfdump -R "$range_path" -o csv -s dstip/bytes -n 5 -q 2>/dev/null || true)"
  rank=0
  while IFS=',' read -r _ _ _ _ ip _ _ packets _ bytes _ _ _ _; do
    [[ "$ip" == "val" ]] && continue
    [[ -z "$ip" || "$ip" == "No matching flows" ]] && continue
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    [[ "$packets" =~ ^[0-9]+$ ]] || packets=0
    rank=$((rank + 1))
    emit_metric "$metrics_file" "osyrus_netflow_top_dst_bytes" "$bytes" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP" "rank=$rank" "dst_ip=$ip"
    emit_metric "$metrics_file" "osyrus_netflow_top_dst_packets" "$packets" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP" "rank=$rank" "dst_ip=$ip"
  done <<<"$top_dst"

  top_proto="$(nfdump -R "$range_path" -o csv -s proto/bytes -n 8 -q 2>/dev/null || true)"
  while IFS=',' read -r _ _ _ _ proto _ _ packets _ bytes _ _ _ _; do
    [[ "$proto" == "val" ]] && continue
    [[ -z "$proto" || "$proto" == "No matching flows" ]] && continue
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    [[ "$packets" =~ ^[0-9]+$ ]] || packets=0
    emit_metric "$metrics_file" "osyrus_netflow_proto_bytes" "$bytes" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP" "protocol=$proto"
    emit_metric "$metrics_file" "osyrus_netflow_proto_packets" "$packets" \
      "switch_name=$NETFLOW_SWITCH_NAME" "switch_ip=$NETFLOW_SWITCH_IP" "protocol=$proto"
  done <<<"$top_proto"

  log "HEALTH netflow_metrics_updated range=$range_path flows=$flows_total packets=$packets_total bytes=$bytes_total"
}

collect_capacity_metrics() {
  mkdir -p "$NODE_EXPORTER_TEXTFILE_DIR"
  local tmp_file="${CAPACITY_METRICS_FILE}.tmp.$$"
  : >"$tmp_file"

  cat >>"$tmp_file" <<EOF
# HELP osyrus_capacity_last_run_timestamp_seconds Unix epoch timestamp when capacity checks last ran.
# TYPE osyrus_capacity_last_run_timestamp_seconds gauge
# HELP osyrus_remote_filesystem_collection_success 1 when remote filesystem scan succeeded for host, else 0.
# TYPE osyrus_remote_filesystem_collection_success gauge
# HELP osyrus_remote_filesystem_size_bytes Remote filesystem total bytes.
# TYPE osyrus_remote_filesystem_size_bytes gauge
# HELP osyrus_remote_filesystem_used_bytes Remote filesystem used bytes.
# TYPE osyrus_remote_filesystem_used_bytes gauge
# HELP osyrus_remote_filesystem_avail_bytes Remote filesystem available bytes.
# TYPE osyrus_remote_filesystem_avail_bytes gauge
# HELP osyrus_remote_filesystem_used_percent Remote filesystem used percent from df.
# TYPE osyrus_remote_filesystem_used_percent gauge
# HELP osyrus_remote_root_used_percent Remote root filesystem used percent.
# TYPE osyrus_remote_root_used_percent gauge
# HELP osyrus_remote_log_files_older_than_days Count of /var/log files older than configured retention window.
# TYPE osyrus_remote_log_files_older_than_days gauge
# HELP osyrus_remote_log_bytes_older_than_days Bytes of /var/log files older than configured retention window.
# TYPE osyrus_remote_log_bytes_older_than_days gauge
# HELP osyrus_remote_var_log_size_bytes Total /var/log size in bytes per host.
# TYPE osyrus_remote_var_log_size_bytes gauge
# HELP osyrus_esxi_datastore_collection_success 1 when ESXi datastore scan succeeded for host, else 0.
# TYPE osyrus_esxi_datastore_collection_success gauge
# HELP osyrus_esxi_datastore_capacity_bytes ESXi datastore total bytes.
# TYPE osyrus_esxi_datastore_capacity_bytes gauge
# HELP osyrus_esxi_datastore_free_bytes ESXi datastore free bytes.
# TYPE osyrus_esxi_datastore_free_bytes gauge
# HELP osyrus_esxi_datastore_used_bytes ESXi datastore used bytes.
# TYPE osyrus_esxi_datastore_used_bytes gauge
# HELP osyrus_esxi_datastore_uncommitted_bytes ESXi datastore uncommitted bytes.
# TYPE osyrus_esxi_datastore_uncommitted_bytes gauge
# HELP osyrus_esxi_datastore_used_percent ESXi datastore used percent.
# TYPE osyrus_esxi_datastore_used_percent gauge
# HELP osyrus_esxi_host_collection_success 1 when ESXi host quickstats scan succeeded, else 0.
# TYPE osyrus_esxi_host_collection_success gauge
# HELP osyrus_esxi_host_cpu_capacity_mhz ESXi host total CPU capacity in MHz.
# TYPE osyrus_esxi_host_cpu_capacity_mhz gauge
# HELP osyrus_esxi_host_cpu_used_mhz ESXi host current CPU usage in MHz.
# TYPE osyrus_esxi_host_cpu_used_mhz gauge
# HELP osyrus_esxi_host_cpu_used_percent ESXi host CPU utilization percent.
# TYPE osyrus_esxi_host_cpu_used_percent gauge
# HELP osyrus_esxi_host_memory_total_bytes ESXi host total memory in bytes.
# TYPE osyrus_esxi_host_memory_total_bytes gauge
# HELP osyrus_esxi_host_memory_used_bytes ESXi host used memory in bytes.
# TYPE osyrus_esxi_host_memory_used_bytes gauge
# HELP osyrus_esxi_host_memory_free_bytes ESXi host free memory in bytes.
# TYPE osyrus_esxi_host_memory_free_bytes gauge
# HELP osyrus_esxi_host_memory_used_percent ESXi host memory utilization percent.
# TYPE osyrus_esxi_host_memory_used_percent gauge
# HELP osyrus_switch_collection_success 1 when switch telemetry collection succeeded, else 0.
# TYPE osyrus_switch_collection_success gauge
# HELP osyrus_switch_ports_total Total physical access ports discovered on switch.
# TYPE osyrus_switch_ports_total gauge
# HELP osyrus_switch_ports_up Total physical access ports in link-up state.
# TYPE osyrus_switch_ports_up gauge
# HELP osyrus_switch_port_error_interfaces Count of switch ports currently reporting input/output errors.
# TYPE osyrus_switch_port_error_interfaces gauge
# HELP osyrus_switch_system_alarms_total Active system alarms on switch.
# TYPE osyrus_switch_system_alarms_total gauge
# HELP osyrus_switch_chassis_alarms_total Active chassis alarms on switch.
# TYPE osyrus_switch_chassis_alarms_total gauge
# HELP osyrus_switch_netflow_enabled 1 when netflow/sampling config is present on switch.
# TYPE osyrus_switch_netflow_enabled gauge
# HELP osyrus_switch_sflow_enabled 1 when sFlow config is present on switch.
# TYPE osyrus_switch_sflow_enabled gauge
# HELP osyrus_switch_circuit_health_score Composite circuit health score (0-100).
# TYPE osyrus_switch_circuit_health_score gauge
# HELP osyrus_switch_port_admin_up Switch port admin state (1=up,0=down).
# TYPE osyrus_switch_port_admin_up gauge
# HELP osyrus_switch_port_link_up Switch port link state (1=up,0=down).
# TYPE osyrus_switch_port_link_up gauge
# HELP osyrus_switch_port_input_bps Switch port input throughput in bits per second.
# TYPE osyrus_switch_port_input_bps gauge
# HELP osyrus_switch_port_output_bps Switch port output throughput in bits per second.
# TYPE osyrus_switch_port_output_bps gauge
# HELP osyrus_switch_port_input_pps Switch port input packets per second.
# TYPE osyrus_switch_port_input_pps gauge
# HELP osyrus_switch_port_output_pps Switch port output packets per second.
# TYPE osyrus_switch_port_output_pps gauge
# HELP osyrus_switch_port_input_errors Switch port input errors.
# TYPE osyrus_switch_port_input_errors gauge
# HELP osyrus_switch_port_output_errors Switch port output errors.
# TYPE osyrus_switch_port_output_errors gauge
# HELP osyrus_switch_port_mac_learned_count Count of learned MAC addresses on switch port.
# TYPE osyrus_switch_port_mac_learned_count gauge
# HELP osyrus_switch_port_interface_mac_info Interface MAC identity marker (always 1, labels carry identity).
# TYPE osyrus_switch_port_interface_mac_info gauge
# HELP osyrus_switch_port_observed_client Observed client on switch port (always 1, labels carry MAC/IP mapping).
# TYPE osyrus_switch_port_observed_client gauge
# HELP osyrus_netflow_collection_success 1 when NetFlow summary collection succeeded, else 0.
# TYPE osyrus_netflow_collection_success gauge
# HELP osyrus_netflow_flows_total Total NetFlow records seen across selected files.
# TYPE osyrus_netflow_flows_total gauge
# HELP osyrus_netflow_packets_total Total sampled packets seen across selected files.
# TYPE osyrus_netflow_packets_total gauge
# HELP osyrus_netflow_bytes_total Total sampled bytes seen across selected files.
# TYPE osyrus_netflow_bytes_total gauge
# HELP osyrus_netflow_sequence_failures_total NetFlow sequence failures in selected files.
# TYPE osyrus_netflow_sequence_failures_total gauge
# HELP osyrus_netflow_top_src_bytes Top source IP sampled bytes (ranked labels).
# TYPE osyrus_netflow_top_src_bytes gauge
# HELP osyrus_netflow_top_src_packets Top source IP sampled packets (ranked labels).
# TYPE osyrus_netflow_top_src_packets gauge
# HELP osyrus_netflow_top_dst_bytes Top destination IP sampled bytes (ranked labels).
# TYPE osyrus_netflow_top_dst_bytes gauge
# HELP osyrus_netflow_top_dst_packets Top destination IP sampled packets (ranked labels).
# TYPE osyrus_netflow_top_dst_packets gauge
# HELP osyrus_netflow_proto_bytes NetFlow sampled bytes by IP protocol.
# TYPE osyrus_netflow_proto_bytes gauge
# HELP osyrus_netflow_proto_packets NetFlow sampled packets by IP protocol.
# TYPE osyrus_netflow_proto_packets gauge
EOF

  emit_metric "$tmp_file" "osyrus_capacity_last_run_timestamp_seconds" "$(date +%s)"

  local target host_name host_ip host_user host_pass
  for target in "${DISK_SSH_TARGETS[@]}"; do
    IFS='|' read -r host_name host_ip host_user host_pass <<<"$target"
    collect_remote_disk_metrics "$tmp_file" "$host_name" "$host_ip" "$host_user" "$host_pass" || true
  done

  collect_esxi_datastore_metrics "$tmp_file" "$VM1_HOST" || true
  collect_esxi_datastore_metrics "$tmp_file" "$VM2_HOST" || true
  collect_esxi_host_resource_metrics "$tmp_file" "$VM1_HOST" || true
  collect_esxi_host_resource_metrics "$tmp_file" "$VM2_HOST" || true

  local switch_target switch_name switch_ip switch_user switch_pass
  for switch_target in "${JUNOS_SWITCH_TARGETS[@]}"; do
    IFS='|' read -r switch_name switch_ip switch_user switch_pass <<<"$switch_target"
    collect_junos_switch_metrics "$tmp_file" "$switch_name" "$switch_ip" "$switch_user" "$switch_pass" || true
  done
  collect_netflow_metrics "$tmp_file" || true

  mv "$tmp_file" "$CAPACITY_METRICS_FILE"
  log "HEALTH capacity_metrics_updated file=$CAPACITY_METRICS_FILE"
}

collect_spark_image_metrics() {
  if [[ ! -f "$SPARK_IMAGE_METRICS_SCRIPT" ]]; then
    log "WARN spark_image_metrics_missing script=$SPARK_IMAGE_METRICS_SCRIPT"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log "WARN spark_image_metrics_skipped reason=missing_python3"
    return 0
  fi
  if python3 "$SPARK_IMAGE_METRICS_SCRIPT" >/tmp/osyrus-agent-spark-image-metrics.$$ 2>&1; then
    log "HEALTH spark_image_metrics_updated script=$SPARK_IMAGE_METRICS_SCRIPT"
  else
    log "WARN spark_image_metrics_failed script=$SPARK_IMAGE_METRICS_SCRIPT details=$(tr '\n' ' ' </tmp/osyrus-agent-spark-image-metrics.$$)"
  fi
  rm -f /tmp/osyrus-agent-spark-image-metrics.$$
}

collect_public_chat_vrrp_metrics() {
  if [[ ! -f "$PUBLIC_CHAT_VRRP_METRICS_SCRIPT" ]]; then
    log "WARN public_chat_vrrp_metrics_missing script=$PUBLIC_CHAT_VRRP_METRICS_SCRIPT"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log "WARN public_chat_vrrp_metrics_skipped reason=missing_python3"
    return 0
  fi
  if python3 "$PUBLIC_CHAT_VRRP_METRICS_SCRIPT" >/tmp/osyrus-agent-public-chat-vrrp-metrics.$$ 2>&1; then
    log "HEALTH public_chat_vrrp_metrics_updated script=$PUBLIC_CHAT_VRRP_METRICS_SCRIPT"
  else
    log "WARN public_chat_vrrp_metrics_failed script=$PUBLIC_CHAT_VRRP_METRICS_SCRIPT details=$(tr '\n' ' ' </tmp/osyrus-agent-public-chat-vrrp-metrics.$$)"
  fi
  rm -f /tmp/osyrus-agent-public-chat-vrrp-metrics.$$
}

collect_web_ha_metrics() {
  if [[ ! -f "$WEB_HA_METRICS_SCRIPT" ]]; then
    log "WARN web_ha_metrics_missing script=$WEB_HA_METRICS_SCRIPT"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log "WARN web_ha_metrics_skipped reason=missing_python3"
    return 0
  fi
  if python3 "$WEB_HA_METRICS_SCRIPT" >/tmp/osyrus-agent-web-ha-metrics.$$ 2>&1; then
    log "HEALTH web_ha_metrics_updated script=$WEB_HA_METRICS_SCRIPT"
  else
    log "WARN web_ha_metrics_degraded script=$WEB_HA_METRICS_SCRIPT details=$(tr '\n' ' ' </tmp/osyrus-agent-web-ha-metrics.$$)"
  fi
  rm -f /tmp/osyrus-agent-web-ha-metrics.$$
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  log "START"

  need_cmd govc || exit 1
  need_cmd jq || exit 1
  need_cmd sshpass || exit 1
  need_cmd nc || exit 1

  ensure_host_vms_on "$VM1_HOST" || true
  ensure_host_vms_on "$VM2_HOST" || true
  ensure_observability_stack || true
  critical_reachability_summary
  collect_capacity_metrics || true
  collect_spark_image_metrics || true
  collect_public_chat_vrrp_metrics || true
  collect_web_ha_metrics || true

  log "END"
}

main "$@"
