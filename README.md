# Osyrus Portal

Single-page dashboard for `vm1` (`192.168.12.148`) and `vm2` (`192.168.12.217`) showing:
- datastores (GB/TB usage)
- VMs (powered on/off, IP, CPU, RAM, guest OS)
- template/image-like VMs
- ISO images present on each datastore
- vulnerability profile by host (CVE counts/severity/remediation %)
- upgrade-path actions per host profile

## Files
- `generate_inventory.sh`: pulls live inventory from both ESXi hosts via `govc`
- `inventory.json`: generated inventory data used by the portal
- `run_vulnerability_scan.sh`: runs nmap service scan + CVE enrichment on all host/VM IPs in inventory
- `generate_vulnerability_report.py`: converts scan XML to `vulnerability_report.json` + `VULN_UPGRADE_PATH_PLAN.md`
- `remediation_status.json`: manual remediation tracker (set remediated CVE IDs by host IP)
- `index.html`: dashboard UI
- `start_portal.sh`: refreshes inventory and starts local web server on port 8080
- `watch_inventory.sh`: refresh loop (default every 60s)
- `server.js`, `package.json`, `render.yaml`: Render-ready public hosting bundle

## Refresh Inventory
```bash
cd "/Users/nation/Documents/New project/vmware-powercli/portal"
./generate_inventory.sh
```

Credentials are required:
```bash
VM1_USER=root VM1_PASS='your-pass' VM2_USER=root VM2_PASS='your-pass' ./generate_inventory.sh
```

## Run Vulnerability Scan
```bash
cd "/Users/nation/Documents/New project/vmware-powercli/portal"
./run_vulnerability_scan.sh
```
Outputs:
- `vuln_scan_services.xml` / `.txt`
- `vuln_scan_cve.xml` / `.txt`
- `vulnerability_report.json`
- `VULN_UPGRADE_PATH_PLAN.md`

Remediation tracking:
- update `remediation_status.json` with CVE IDs under each asset IP in `remediated_cves`
- refresh page to update `% remediated` in dashboard and host profile

## Scanner Node (osyrus-scan-01)

Scanner node artifacts are under `scanner-node/`.

- `run_scan_node.sh`: fetch targets from portal inventory, run scans, push artifacts back to portal host
- `osyrus-scanner.service` + `osyrus-scanner.timer`: scheduled scanner pipeline (hourly)
- `install_scanner_node.sh`: helper installer for the scanner VM

Portal data file:
- `scanner_nodes.json` (displayed in Osyrus UI as **Scanning Nodes**)

## Run Portal
```bash
cd "/Users/nation/Documents/New project/vmware-powercli/portal"
python3 -m http.server 8080
```
Open: `http://localhost:8080`

One-command start:
```bash
cd "/Users/nation/Documents/New project/vmware-powercli/portal"
./start_portal.sh
```

`start_portal.sh` keeps inventory fresh by running `watch_inventory.sh` in the background.
If port `8080` is busy, run `PORT=8090 ./start_portal.sh`.

The page auto-refreshes `inventory.json` every 60 seconds. Click **Refresh** to reload on demand.

## Render Deployment (Public)
1. Push this `portal` directory to a Git repository.
2. In Render, create a new **Blueprint** service and point it to the repo.
3. Use `render.yaml` in this directory.
4. Deploy. Render starts `npm start` and serves the portal from `server.js`.
