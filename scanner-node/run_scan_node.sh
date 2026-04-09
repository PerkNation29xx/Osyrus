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

mkdir -p "${WORK_DIR}/reports"

INVENTORY_JSON="${WORK_DIR}/inventory.json"
SERVICES_XML="${WORK_DIR}/reports/vuln_scan_services.xml"
SERVICES_TXT="${WORK_DIR}/reports/vuln_scan_services.txt"
CVE_XML="${WORK_DIR}/reports/vuln_scan_cve.xml"
CVE_TXT="${WORK_DIR}/reports/vuln_scan_cve.txt"
SCANNER_JSON="${WORK_DIR}/scanner_nodes.json"
WEB_APPS_JSON="${WORK_DIR}/web_apps_inventory.json"

START_EPOCH="$(date -u +%s)"
START_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

curl -fsSL "http://${PORTAL_HOST}:8090/inventory.json" -o "${INVENTORY_JSON}"

mapfile -t TARGETS < <(
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

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No targets found in inventory.json" >&2
  exit 1
fi

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
        last_scan_duration_seconds: $duration_seconds,
        last_remediation_percent: $remediation_percent,
        last_scan_started: $start_ts,
        last_scan_completed: $end_ts,
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

rsync -av -e "ssh -o StrictHostKeyChecking=no" \
  "${SCANNER_JSON}" \
  "${PORTAL_USER}@${PORTAL_HOST}:${PORTAL_DIR}/"

if [[ -f "${WEB_APPS_JSON}" ]]; then
  rsync -av -e "ssh -o StrictHostKeyChecking=no" \
    "${WEB_APPS_JSON}" \
    "${PORTAL_USER}@${PORTAL_HOST}:${PORTAL_DIR}/"
fi

echo "Scanner run complete (${END_TS})"
