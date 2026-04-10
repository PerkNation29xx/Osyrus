#!/usr/bin/env python3
"""Generate security stack service inventory for Osyrus."""

from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_JSON = BASE_DIR / "security_stack_inventory.json"

SERVICES = [
    {
        "id": "wazuh",
        "name": "Wazuh Dashboard",
        "category": "SIEM/XDR",
        "host": "osyrus-wazuh-01",
        "ip": "192.168.12.241",
        "url": "https://192.168.12.241/",
        "credentials": "admin / (stored on host at /tmp/wazuh-install.log)",
        "notes": "Wazuh manager, indexer, and dashboard all-in-one node",
    },
    {
        "id": "opensearch",
        "name": "OpenSearch Dashboards",
        "category": "SIEM Search",
        "host": "osyrus-opensearch-01",
        "ip": "192.168.12.242",
        "url": "http://192.168.12.242:5601/",
        "credentials": "No auth (security plugin disabled for lab)",
        "notes": "Single-node OpenSearch + Dashboards",
    },
    {
        "id": "shuffle",
        "name": "Shuffle SOAR",
        "category": "SOAR",
        "host": "osyrus-shuffle-01",
        "ip": "192.168.12.243",
        "url": "http://192.168.12.243:3001/",
        "credentials": "Create admin on first login",
        "notes": "Workflow automation and response orchestration",
    },
    {
        "id": "ansible",
        "name": "Semaphore (Ansible UI)",
        "category": "Patch Orchestration",
        "host": "osyrus-ansible-01",
        "ip": "192.168.12.244",
        "url": "http://192.168.12.244:3000/",
        "credentials": "admin / stored in vault",
        "notes": "Ansible control node with Semaphore UI",
    },
    {
        "id": "grafana",
        "name": "Grafana",
        "category": "Observability",
        "host": "osyrus-observability-01",
        "ip": "192.168.12.245",
        "url": "http://192.168.12.245:3000/",
        "credentials": "admin / stored in vault",
        "notes": "Dashboards for vulnerability and host metrics",
    },
    {
        "id": "prometheus",
        "name": "Prometheus",
        "category": "Observability",
        "host": "osyrus-observability-01",
        "ip": "192.168.12.245",
        "url": "http://192.168.12.245:9090/",
        "credentials": "No auth (lab)",
        "notes": "Metrics scraping and alert source",
    },
]


def probe(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "osyrus-security-stack/1.0"})
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(request, timeout=8, context=context) as response:
            return {
                "reachable": True,
                "status": int(getattr(response, "status", 0) or 0),
                "final_url": response.geturl(),
                "error": "",
            }
    except urllib.error.HTTPError as err:
        return {
            "reachable": True,
            "status": int(err.code),
            "final_url": url,
            "error": f"HTTPError {err.code}",
        }
    except Exception as err:  # noqa: BLE001
        return {
            "reachable": False,
            "status": 0,
            "final_url": "",
            "error": str(err),
        }


def main() -> int:
    items = []
    for service in SERVICES:
        probe_result = probe(service["url"])
        items.append({**service, **probe_result})

    payload = {
        "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total_services": len(items),
        "reachable_services": sum(1 for item in items if item["reachable"]),
        "items": items,
    }
    OUTPUT_JSON.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Wrote: {OUTPUT_JSON}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
