#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOST="${1:-devops@192.168.12.240}"

scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/run_scan_node.sh" "${TARGET_HOST}:/tmp/run_scan_node.sh"
scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/osyrus-scanner.service" "${TARGET_HOST}:/tmp/osyrus-scanner.service"
scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/osyrus-scanner.timer" "${TARGET_HOST}:/tmp/osyrus-scanner.timer"
scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/../generate_web_apps_inventory.py" "${TARGET_HOST}:/tmp/generate_web_apps_inventory.py"

ssh -o StrictHostKeyChecking=no "${TARGET_HOST}" <<'EOSSH'
set -euo pipefail
sudo -n mkdir -p /opt/osyrus-scanner/reports
sudo -n mv /tmp/run_scan_node.sh /opt/osyrus-scanner/run_scan_node.sh
sudo -n chmod 750 /opt/osyrus-scanner/run_scan_node.sh
sudo -n chown root:devops /opt/osyrus-scanner/run_scan_node.sh
sudo -n mv /tmp/generate_web_apps_inventory.py /opt/osyrus-scanner/generate_web_apps_inventory.py
sudo -n chmod 750 /opt/osyrus-scanner/generate_web_apps_inventory.py
sudo -n chown root:devops /opt/osyrus-scanner/generate_web_apps_inventory.py

sudo -n mv /tmp/osyrus-scanner.service /etc/systemd/system/osyrus-scanner.service
sudo -n mv /tmp/osyrus-scanner.timer /etc/systemd/system/osyrus-scanner.timer
sudo -n chmod 644 /etc/systemd/system/osyrus-scanner.service /etc/systemd/system/osyrus-scanner.timer
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now osyrus-scanner.timer
sudo -n systemctl start osyrus-scanner.service
sudo -n systemctl status osyrus-scanner.service --no-pager -l || true
sudo -n systemctl status osyrus-scanner.timer --no-pager -l || true
EOSSH
