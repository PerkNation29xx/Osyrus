#!/usr/bin/env python3
"""Generate security stack service inventory for Osyrus."""

from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_JSON = BASE_DIR / "security_stack_inventory.json"

SERVICES = [
    {
        "id": "wazuh",
        "name": "Wazuh Dashboard",
        "category": "SIEM/XDR",
        "host": "osyrus-wazuh-01",
        "host_fqdn": "osyrus-wazuh-01.homelab.arpa",
        "ip": "192.168.12.241",
        "url": "https://osyrus-wazuh-01.homelab.arpa/",
        "probe_url": "https://192.168.12.241/",
        "credentials": "admin / (stored on host at /tmp/wazuh-install.log)",
        "notes": "Wazuh manager, indexer, and dashboard all-in-one node",
    },
    {
        "id": "opensearch",
        "name": "OpenSearch Dashboards",
        "category": "SIEM Search",
        "host": "osyrus-opensearch-01",
        "host_fqdn": "osyrus-opensearch-01.homelab.arpa",
        "ip": "192.168.12.242",
        "url": "http://osyrus-opensearch-01.homelab.arpa:5601/",
        "probe_url": "http://192.168.12.242:5601/",
        "credentials": "No auth (security plugin disabled for lab)",
        "notes": "Single-node OpenSearch + Dashboards",
    },
    {
        "id": "shuffle",
        "name": "Shuffle SOAR",
        "category": "SOAR",
        "host": "osyrus-shuffle-01",
        "host_fqdn": "osyrus-shuffle-01.homelab.arpa",
        "ip": "192.168.12.243",
        "url": "http://osyrus-shuffle-01.homelab.arpa:3001/",
        "probe_url": "http://192.168.12.243:3001/",
        "credentials": "Create admin on first login",
        "notes": "Workflow automation and response orchestration",
    },
    {
        "id": "ansible",
        "name": "Semaphore (Ansible UI)",
        "category": "Patch Orchestration",
        "host": "osyrus-ansible-01",
        "host_fqdn": "osyrus-ansible-01.homelab.arpa",
        "ip": "192.168.12.244",
        "url": "http://osyrus-ansible-01.homelab.arpa:3000/",
        "probe_url": "http://192.168.12.244:3000/",
        "credentials": "admin / stored in vault",
        "notes": "Ansible control node with Semaphore UI",
    },
    {
        "id": "grafana",
        "name": "Grafana",
        "category": "Observability",
        "host": "osyrus-observability-01",
        "host_fqdn": "grafana.homelab.arpa",
        "ip": "192.168.12.245",
        "url": "http://grafana.homelab.arpa:3000/",
        "probe_url": "http://192.168.12.245:3000/",
        "credentials": "admin / stored in vault",
        "notes": "Dashboards for vulnerability and host metrics",
    },
    {
        "id": "prometheus",
        "name": "Prometheus",
        "category": "Observability",
        "host": "osyrus-observability-01",
        "host_fqdn": "prometheus.homelab.arpa",
        "ip": "192.168.12.245",
        "url": "http://prometheus.homelab.arpa:9090/",
        "probe_url": "http://192.168.12.245:9090/",
        "credentials": "No auth (lab)",
        "notes": "Metrics scraping and alert source",
    },
    {
        "id": "loki",
        "name": "Loki",
        "category": "Observability Logs",
        "host": "osyrus-observability-01",
        "host_fqdn": "loki.homelab.arpa",
        "ip": "192.168.12.245",
        "url": "http://loki.homelab.arpa:3100/ready",
        "probe_url": "http://192.168.12.245:3100/ready",
        "credentials": "No auth (lab)",
        "notes": "Log storage/query backend for Grafana",
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


def with_display_host(base_url: str, observed_url: str) -> str:
    if not observed_url:
        return base_url

    base = urlsplit(base_url)
    observed = urlsplit(observed_url)
    scheme = base.scheme or observed.scheme
    netloc = base.netloc or observed.netloc
    path = observed.path or base.path or "/"
    return urlunsplit((scheme, netloc, path, observed.query, observed.fragment))


def main() -> int:
    items = []
    for service in SERVICES:
        probe_url = service.get("probe_url", service["url"])
        probe_result = probe(probe_url)
        service_item = {k: v for k, v in service.items() if k != "probe_url"}
        probe_result["final_url"] = with_display_host(service_item["url"], probe_result["final_url"])
        items.append({**service_item, **probe_result})

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
