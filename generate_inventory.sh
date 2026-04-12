#!/usr/bin/env bash
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_JSON="${SCRIPT_DIR}/inventory.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd govc
require_cmd jq

# Credentials must be provided via environment variables.
VM1_USER="${VM1_USER:-root}"
VM1_PASS="${VM1_PASS:-}"
VM2_USER="${VM2_USER:-root}"
VM2_PASS="${VM2_PASS:-}"

if [[ -z "$VM1_PASS" || -z "$VM2_PASS" ]]; then
  cat >&2 <<'EOF'
Missing required credentials.
Set VM1_PASS and VM2_PASS in your environment before running this script.
Example:
  VM1_USER=root VM1_PASS='...' VM2_USER=root VM2_PASS='...' ./generate_inventory.sh
EOF
  exit 1
fi

collect_host() {
  local alias="$1"
  local ip="$2"
  local user="$3"
  local pass="$4"

  export GOVC_URL="$ip"
  export GOVC_USERNAME="$user"
  export GOVC_PASSWORD="$pass"
  export GOVC_INSECURE=1

  local host_dir="$TMP_DIR/$alias"
  mkdir -p "$host_dir"

  if ! govc about -json >"$host_dir/about.json" 2>"$host_dir/error.log"; then
    jq -n \
      --arg alias "$alias" \
      --arg ip "$ip" \
      --arg error "$(<"$host_dir/error.log")" \
      '{alias:$alias, ip:$ip, status:"error", error:$error}'
    return 0
  fi

  govc datastore.info -json >"$host_dir/datastores.json"

  local vm_items="$host_dir/vm-items.jsonl"
  : >"$vm_items"

  while IFS= read -r vm_path; do
    [[ -z "$vm_path" ]] && continue
    local vm_name="${vm_path##*/}"
    local safe_vm_name
    safe_vm_name="$(echo "$vm_name" | tr ' /:\\' '____')"

    local vm_props="$host_dir/vm-${safe_vm_name}-props.json"
    if govc object.collect -json "$vm_path" \
      name \
      summary.runtime.powerState \
      summary.guest.ipAddress \
      summary.guest.hostName \
      summary.config.guestFullName \
      summary.config.numCpu \
      summary.config.memorySizeMB \
      config.template \
      summary.config.vmPathName >"$vm_props" 2>/dev/null; then

      local vm_extra="$host_dir/vm-${safe_vm_name}-extra.txt"
      local os_pretty=""
      if govc vm.info -e "$vm_name" >"$vm_extra" 2>/dev/null; then
        os_pretty="$(
          awk -F'guestInfo.detailed.data:' '/guestInfo.detailed.data:/ {sub(/^[[:space:]]*/, "", $2); print $2; exit}' "$vm_extra" \
            | sed -n "s/.*prettyName='\([^']*\)'.*/\1/p"
        )"
      fi

      jq -c --arg vm_name "$vm_name" --arg os_pretty "$os_pretty" '
        (reduce .[] as $item ({}; .[$item.name] = $item.val)) as $m
        | {
            name: ($m.name // $vm_name),
            power_state: ($m["summary.runtime.powerState"] // "unknown"),
            guest_ip: ($m["summary.guest.ipAddress"] // ""),
            host_name: ($m["summary.guest.hostName"] // ""),
            guest_os: ($m["summary.config.guestFullName"] // ""),
            guest_os_version: $os_pretty,
            num_cpu: ($m["summary.config.numCpu"] // 0),
            memory_gb: (((($m["summary.config.memorySizeMB"] // 0) / 1024) | floor)),
            template: ($m["config.template"] // false),
            vmx_path: ($m["summary.config.vmPathName"] // "")
          }
      ' "$vm_props" >>"$vm_items"
    fi
  done < <(govc find /ha-datacenter/vm -type m | sort)

  local iso_items="$host_dir/iso-items.jsonl"
  : >"$iso_items"

  while IFS= read -r ds_name; do
    [[ -z "$ds_name" ]] && continue

    while IFS= read -r iso_file; do
      [[ -z "$iso_file" ]] && continue
      jq -cn \
        --arg datastore "$ds_name" \
        --arg file "$iso_file" \
        '{datastore:$datastore, file:$file}' >>"$iso_items"
    done < <(
      if command -v rg >/dev/null 2>&1; then
        govc datastore.ls -ds "$ds_name" -R | rg -i '\.iso$' || true
      else
        govc datastore.ls -ds "$ds_name" -R | grep -Ei '\.iso$' || true
      fi
    )
  done < <(jq -r '.datastores[].summary.name' "$host_dir/datastores.json")

  local vms_json='[]'
  local isos_json='[]'

  if [[ -s "$vm_items" ]]; then
    vms_json="$(jq -s 'sort_by(.name)' "$vm_items")"
  fi

  if [[ -s "$iso_items" ]]; then
    isos_json="$(jq -s 'sort_by(.datastore, .file)' "$iso_items")"
  fi

  jq -n \
    --arg alias "$alias" \
    --arg ip "$ip" \
    --argjson about "$(cat "$host_dir/about.json")" \
    --argjson datastores_raw "$(cat "$host_dir/datastores.json")" \
    --argjson vms "$vms_json" \
    --argjson isos "$isos_json" \
    '
      {
        alias: $alias,
        ip: $ip,
        status: "ok",
        host: {
          full_name: ($about.about.fullName // ""),
          name: ($about.about.name // ""),
          version: ($about.about.version // ""),
          build: ($about.about.build // "")
        },
        datastores: [
          $datastores_raw.datastores[].summary | {
            name,
            type,
            accessible,
            capacity_gb: ((.capacity / 1073741824) | floor),
            free_gb: ((.freeSpace / 1073741824) | floor),
            used_gb: (((.capacity - .freeSpace) / 1073741824) | floor),
            free_tb: ((.freeSpace / 1099511627776) * 100 | round / 100)
          }
        ] | sort_by(.name),
        vms: $vms,
        images: (
          $vms
          | map(select(.template == true or (.name | test("template|base|image"; "i"))))
          | map({name, guest_os, power_state, template})
        ),
        iso_images: $isos,
        counts: {
          vm_total: ($vms | length),
          vm_powered_on: ($vms | map(select(.power_state == "poweredOn")) | length),
          vm_powered_off: ($vms | map(select(.power_state == "poweredOff")) | length),
          datastore_total: ($datastores_raw.datastores | length),
          iso_total: ($isos | length)
        }
      }
    '
}

HOSTS_JSON="$TMP_DIR/hosts.jsonl"
: >"$HOSTS_JSON"

collect_host "vm1" "192.168.12.148" "$VM1_USER" "$VM1_PASS" >>"$HOSTS_JSON"
collect_host "vm2" "192.168.12.217" "$VM2_USER" "$VM2_PASS" >>"$HOSTS_JSON"

jq -s \
  --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{generated_at:$generated_at, hosts:.}' \
  "$HOSTS_JSON" >"$OUT_JSON"

echo "Wrote inventory: $OUT_JSON"

if [[ -n "${DATABASE_URL:-}" && -f "${SCRIPT_DIR}/scripts/db/seed_from_json.js" ]] && command -v node >/dev/null 2>&1; then
  node "${SCRIPT_DIR}/scripts/db/seed_from_json.js" --dataset inventory --only-if-changed --quiet >/dev/null 2>&1 || true
fi
