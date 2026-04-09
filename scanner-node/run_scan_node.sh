#!/usr/bin/env bash
set -euo pipefail

NODE_ID="${NODE_ID:-osyrus-scan-01}"
NODE_NAME="${NODE_NAME:-osyrus-scan-01}"
NODE_ROLE="${NODE_ROLE:-primary-vuln-scanner}"
PORTAL_HOST="${PORTAL_HOST:-192.168.12.136}"
PORTAL_USER="${PORTAL_USER:-devops}"
PORTAL_DIR="${PORTAL_DIR:-/home/devops/vm-portal}"
WORK_DIR="${WORK_DIR:-/opt/osyrus-scanner}"
SCHEDULE="${SCHEDULE:-hourly}"
DISCOVERY_ENABLED="${DISCOVERY_ENABLED:-true}"
DISCOVERY_CIDRS="${DISCOVERY_CIDRS:-}"
DISCOVERY_EXCLUDE_IPS="${DISCOVERY_EXCLUDE_IPS:-}"

mkdir -p "${WORK_DIR}/reports"

INVENTORY_JSON="${WORK_DIR}/inventory.json"
SERVICES_XML="${WORK_DIR}/reports/vuln_scan_services.xml"
SERVICES_TXT="${WORK_DIR}/reports/vuln_scan_services.txt"
CVE_XML="${WORK_DIR}/reports/vuln_scan_cve.xml"
CVE_TXT="${WORK_DIR}/reports/vuln_scan_cve.txt"
SCANNER_JSON="${WORK_DIR}/scanner_nodes.json"
DISCOVERED_JSON="${WORK_DIR}/discovered_hosts.json"
WEB_APPS_JSON="${WORK_DIR}/web_apps_inventory.json"
INVENTORY_TARGETS_FILE="${WORK_DIR}/reports/inventory_targets.txt"
DISCOVERED_TARGETS_FILE="${WORK_DIR}/reports/discovered_targets.txt"
SCAN_TARGETS_FILE="${WORK_DIR}/reports/scan_targets.txt"

START_EPOCH="$(date -u +%s)"
START_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if [[ -z "${DISCOVERY_CIDRS}" && "${NODE_IP}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
  DISCOVERY_CIDRS="${BASH_REMATCH[1]}.0/24"
fi

DISCOVERY_ENABLED_BOOL=true
if [[ "${DISCOVERY_ENABLED,,}" == "false" || "${DISCOVERY_ENABLED,,}" == "no" || "${DISCOVERY_ENABLED}" == "0" ]]; then
  DISCOVERY_ENABLED_BOOL=false
fi

curl -fsSL "http://${PORTAL_HOST}:8090/inventory.json" -o "${INVENTORY_JSON}"

mapfile -t INVENTORY_TARGETS < <(
  jq -r '
    [
      (.hosts[]?.ip // empty),
      (.hosts[]?.vms[]?.guest_ip // empty)
    ]
    | flatten
    | map(select(. != null and . != ""))
    | unique
    | .[]
  ' "${INVENTORY_JSON}"
)

declare -A INVENTORY_LOOKUP=()
for ip in "${INVENTORY_TARGETS[@]}"; do
  INVENTORY_LOOKUP["${ip}"]=1
done

read -r -a DISCOVERY_NETS <<< "${DISCOVERY_CIDRS//,/ }"
read -r -a DISCOVERY_EXCLUDES <<< "${DISCOVERY_EXCLUDE_IPS//,/ }"
declare -A EXCLUDE_LOOKUP=()
for ip in "${DISCOVERY_EXCLUDES[@]}"; do
  if [[ -n "${ip}" ]]; then
    EXCLUDE_LOOKUP["${ip}"]=1
  fi
done

DISCOVERED_IPS=()
if [[ "${DISCOVERY_ENABLED_BOOL}" == true && "${#DISCOVERY_NETS[@]}" -gt 0 ]]; then
  DISCOVERY_GNMAP="${WORK_DIR}/reports/discovery_hosts.gnmap"
  : > "${DISCOVERY_GNMAP}"
  for cidr in "${DISCOVERY_NETS[@]}"; do
    if [[ -z "${cidr}" ]]; then
      continue
    fi
    nmap -sn -n "${cidr}" -oG - >> "${DISCOVERY_GNMAP}" || true
  done

  mapfile -t DISCOVERED_IPS < <(
    awk '/Status: Up/{print $2}' "${DISCOVERY_GNMAP}" | awk 'NF' | sort -u
  )
fi

ALL_TARGETS=("${INVENTORY_TARGETS[@]}")
for ip in "${DISCOVERED_IPS[@]}"; do
  if [[ -z "${ip}" ]]; then
    continue
  fi
  if [[ -n "${EXCLUDE_LOOKUP[${ip}]:-}" ]]; then
    continue
  fi
  ALL_TARGETS+=("${ip}")
done

mapfile -t TARGETS < <(printf '%s\n' "${ALL_TARGETS[@]}" | awk 'NF' | sort -u)

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No targets found in inventory.json or discovery sweep" >&2
  exit 1
fi

printf '%s\n' "${INVENTORY_TARGETS[@]}" | awk 'NF' > "${INVENTORY_TARGETS_FILE}"
printf '%s\n' "${DISCOVERED_IPS[@]}" | awk 'NF' > "${DISCOVERED_TARGETS_FILE}"
printf '%s\n' "${TARGETS[@]}" | awk 'NF' > "${SCAN_TARGETS_FILE}"
DISCOVERY_CIDRS_COMMA="$(printf '%s\n' "${DISCOVERY_NETS[@]}" | awk 'NF' | paste -sd, -)"

nmap -Pn -sV --version-light -T4 \
  -oX "${SERVICES_XML}" \
  -oN "${SERVICES_TXT}" \
  "${TARGETS[@]}"

if [[ -f /usr/share/nmap/scripts/vulners.nse ]]; then
  nmap -Pn -sV --version-light --script vulners --script-timeout 20s -T4 \
    -oX "${CVE_XML}" \
    -oN "${CVE_TXT}" \
    "${TARGETS[@]}"
else
  nmap -Pn -sV --version-light -T4 \
    -oX "${CVE_XML}" \
    -oN "${CVE_TXT}" \
    "${TARGETS[@]}"
fi

rsync -av -e "ssh -o StrictHostKeyChecking=no" \
  "${SERVICES_XML}" \
  "${SERVICES_TXT}" \
  "${CVE_XML}" \
  "${CVE_TXT}" \
  "${PORTAL_USER}@${PORTAL_HOST}:${PORTAL_DIR}/"

if [[ -f "${WORK_DIR}/generate_web_apps_inventory.py" ]]; then
  (cd "${WORK_DIR}" && python3 ./generate_web_apps_inventory.py >/dev/null 2>&1 || true)
fi

ssh -o StrictHostKeyChecking=no "${PORTAL_USER}@${PORTAL_HOST}" \
  "cd ${PORTAL_DIR} && ./generate_vulnerability_report.py >/dev/null 2>&1 || true"

REM_PCT="$(curl -fsSL "http://${PORTAL_HOST}:8090/vulnerability_report.json" | jq -r '.summary.remediation_percent // 0' 2>/dev/null || echo 0)"
END_EPOCH="$(date -u +%s)"
END_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DURATION="$((END_EPOCH - START_EPOCH))"
NMAP_VERSION="$(nmap --version | head -n 1 | sed 's/[[:space:]]*$//')"

jq -n \
  --arg generated_at "${END_TS}" \
  --arg node_id "${NODE_ID}" \
  --arg node_name "${NODE_NAME}" \
  --arg node_ip "${NODE_IP}" \
  --arg role "${NODE_ROLE}" \
  --arg schedule "${SCHEDULE}" \
  --arg last_scan_status "success" \
  --arg start_ts "${START_TS}" \
  --arg end_ts "${END_TS}" \
  --argjson target_count "${#TARGETS[@]}" \
  --argjson discovered_count "${#DISCOVERED_IPS[@]}" \
  --argjson discovery_enabled "${DISCOVERY_ENABLED_BOOL}" \
  --arg discovery_cidrs "${DISCOVERY_CIDRS_COMMA}" \
  --argjson duration_seconds "${DURATION}" \
  --argjson remediation_percent "${REM_PCT}" \
  --arg nmap_version "${NMAP_VERSION}" \
  '{
    generated_at: $generated_at,
    nodes: [
      {
        id: $node_id,
        name: $node_name,
        ip: $node_ip,
        status: "online",
        role: $role,
        schedule: $schedule,
        last_scan_status: $last_scan_status,
        last_target_count: $target_count,
        last_discovered_count: $discovered_count,
        last_scan_duration_seconds: $duration_seconds,
        last_remediation_percent: $remediation_percent,
        last_scan_started: $start_ts,
        last_scan_completed: $end_ts,
        discovery: {
          enabled: $discovery_enabled,
          cidrs: ($discovery_cidrs | split(",") | map(select(length > 0)))
        },
        engines: {
          nmap: $nmap_version,
          vulners_script_present: false
        },
        artifacts: {
          services_xml: "vuln_scan_services.xml",
          cve_xml: "vuln_scan_cve.xml"
        }
      }
    ]
  }' > "${SCANNER_JSON}"

# jq cannot directly evaluate local shell boolean from --argjson with command substitution cleanly here,
# so patch the node object with a deterministic value in a second pass.
if [[ -f /usr/share/nmap/scripts/vulners.nse ]]; then
  jq '.nodes[0].engines.vulners_script_present = true' "${SCANNER_JSON}" > "${SCANNER_JSON}.tmp"
else
  jq '.nodes[0].engines.vulners_script_present = false' "${SCANNER_JSON}" > "${SCANNER_JSON}.tmp"
fi
mv "${SCANNER_JSON}.tmp" "${SCANNER_JSON}"

jq -n \
  --arg generated_at "${END_TS}" \
  --arg node_id "${NODE_ID}" \
  --arg node_name "${NODE_NAME}" \
  --arg node_ip "${NODE_IP}" \
  --argjson discovery_enabled "${DISCOVERY_ENABLED_BOOL}" \
  --arg discovery_cidrs "${DISCOVERY_CIDRS_COMMA}" \
  --rawfile inventory_ips "${INVENTORY_TARGETS_FILE}" \
  --rawfile discovered_ips "${DISCOVERED_TARGETS_FILE}" \
  --rawfile scan_ips "${SCAN_TARGETS_FILE}" \
  '
    def lines($text): $text | split("\n") | map(select(length > 0));
    (lines($inventory_ips)) as $inventory
    | (lines($discovered_ips)) as $discovered
    | (lines($scan_ips)) as $scanned
    | {
        generated_at: $generated_at,
        scanner_node: {
          id: $node_id,
          name: $node_name,
          ip: $node_ip
        },
        discovery_enabled: $discovery_enabled,
        discovery_cidrs: ($discovery_cidrs | split(",") | map(select(length > 0))),
        totals: {
          inventory_target_count: ($inventory | length),
          discovered_up_count: ($discovered | length),
          scan_target_count: ($scanned | length)
        },
        hosts: [
          $discovered[] as $ip
          | {
              ip: $ip,
              in_inventory: ($inventory | index($ip) != null)
            }
        ]
      }
  ' > "${DISCOVERED_JSON}"

rsync -av -e "ssh -o StrictHostKeyChecking=no" \
  "${SCANNER_JSON}" \
  "${DISCOVERED_JSON}" \
  "${PORTAL_USER}@${PORTAL_HOST}:${PORTAL_DIR}/"

if [[ -f "${WEB_APPS_JSON}" ]]; then
  rsync -av -e "ssh -o StrictHostKeyChecking=no" \
    "${WEB_APPS_JSON}" \
    "${PORTAL_USER}@${PORTAL_HOST}:${PORTAL_DIR}/"
fi

echo "Scanner run complete (${END_TS})"
