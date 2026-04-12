#!/usr/bin/env python3
"""Discover reachable web app URLs from current inventory."""

from __future__ import annotations

import json
import re
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

BASE_DIR = Path(__file__).resolve().parent
INVENTORY_JSON = BASE_DIR / "inventory.json"
OUTPUT_JSON = BASE_DIR / "web_apps_inventory.json"
DISCOVERED_TARGETS = BASE_DIR / "reports" / "discovered_targets.txt"

WEB_PORTS = [80, 81, 443, 8080, 8081, 8090, 8443, 3000, 3001, 3100, 5000, 5601, 9000, 9080, 9090]

# Canonical DNS view for portal display (probe still runs by IP for reliability).
CANONICAL_DNS_BY_IP: dict[str, str] = {
    "192.168.12.89": "redapple2.homelab.arpa",
    "192.168.12.96": "razasubuntu.homelab.arpa",
    "192.168.12.136": "portal.homelab.arpa",
    "192.168.12.137": "vcsa70.homelab.arpa",
    "192.168.12.147": "redapple3.homelab.arpa",
    "192.168.12.148": "vm1.homelab.arpa",
    "192.168.12.217": "vm2.homelab.arpa",
    "192.168.12.236": "ubuntu24-zt-01.homelab.arpa",
    "192.168.12.240": "osyrus-scan-01.homelab.arpa",
    "192.168.12.241": "osyrus-wazuh-01.homelab.arpa",
    "192.168.12.242": "osyrus-opensearch-01.homelab.arpa",
    "192.168.12.243": "osyrus-shuffle-01.homelab.arpa",
    "192.168.12.244": "osyrus-ansible-01.homelab.arpa",
    "192.168.12.245": "osyrus-observability-01.homelab.arpa",
}

SERVICE_DNS_BY_IP_PORT: dict[tuple[str, int], str] = {
    ("192.168.12.136", 8090): "portal.homelab.arpa",
    ("192.168.12.245", 3000): "grafana.homelab.arpa",
    ("192.168.12.245", 3100): "loki.homelab.arpa",
    ("192.168.12.245", 9080): "promtail.homelab.arpa",
    ("192.168.12.245", 9090): "prometheus.homelab.arpa",
}


def load_inventory() -> dict:
    return json.loads(INVENTORY_JSON.read_text(encoding="utf-8"))


def collect_ips(inventory: dict) -> list[str]:
    ips: set[str] = set()
    for host in inventory.get("hosts", []):
        ip = (host.get("ip") or "").strip()
        if ip:
            ips.add(ip)
        for vm in host.get("vms", []):
            vip = (vm.get("guest_ip") or "").strip()
            if vip:
                ips.add(vip)
    if DISCOVERED_TARGETS.exists():
        for line in DISCOVERED_TARGETS.read_text(encoding="utf-8").splitlines():
            ip = line.strip()
            if ip:
                ips.add(ip)
    return sorted(ips)


def build_ip_assets_map(inventory: dict) -> dict[str, list[dict]]:
    mapping: dict[str, list[dict]] = {}
    for host in inventory.get("hosts", []):
        host_alias = host.get("alias", "")
        host_ip = (host.get("ip") or "").strip()
        if host_ip:
            mapping.setdefault(host_ip, []).append(
                {
                    "type": "esxi_host",
                    "name": host_alias,
                    "host_alias": host_alias,
                }
            )

        for vm in host.get("vms", []):
            vm_ip = (vm.get("guest_ip") or "").strip()
            if not vm_ip:
                continue
            mapping.setdefault(vm_ip, []).append(
                {
                    "type": "vm",
                    "name": vm.get("name", ""),
                    "host_alias": host_alias,
                }
            )

    return mapping


def run_port_scan(ips: list[str]) -> ET.Element:
    with tempfile.NamedTemporaryFile(prefix="osyrus-web-ports-", suffix=".xml", delete=False) as tmp:
        xml_path = Path(tmp.name)

    cmd = [
        "nmap",
        "-Pn",
        "-T4",
        "-p",
        ",".join(str(p) for p in WEB_PORTS),
        *ips,
        "-oX",
        str(xml_path),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    root = ET.parse(xml_path).getroot()
    xml_path.unlink(missing_ok=True)
    return root


def fetch_url(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "osyrus-web-probe/1.0"})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, timeout=5, context=ctx) as resp:
            status = getattr(resp, "status", 0) or 0
            final_url = resp.geturl()
            content = resp.read(220000).decode("utf-8", errors="ignore")
            title_match = re.search(r"<title[^>]*>(.*?)</title>", content, flags=re.I | re.S)
            title = re.sub(r"\s+", " ", title_match.group(1)).strip() if title_match else ""
            server = resp.headers.get("Server", "")
            return {
                "reachable": True,
                "status": status,
                "final_url": final_url,
                "title": title,
                "server": server,
                "error": "",
            }
    except urllib.error.HTTPError as err:
        return {
            "reachable": True,
            "status": err.code,
            "final_url": url,
            "title": "",
            "server": "",
            "error": f"HTTPError {err.code}",
        }
    except Exception as err:  # noqa: BLE001
        return {
            "reachable": False,
            "status": 0,
            "final_url": "",
            "title": "",
            "server": "",
            "error": str(err),
        }


def normalize_fqdn(name: str) -> str:
    text = (name or "").strip()
    if not text:
        return ""
    if "." in text:
        return text.lower()
    if re.fullmatch(r"[A-Za-z0-9-]+", text):
        return f"{text.lower()}.homelab.arpa"
    return ""


def display_dns_name(ip: str, port: int, assets: list[dict]) -> str:
    service_name = SERVICE_DNS_BY_IP_PORT.get((ip, port))
    if service_name:
        return service_name

    canonical = CANONICAL_DNS_BY_IP.get(ip)
    if canonical:
        return canonical

    for asset in assets:
        for key in ("name", "host_alias"):
            fqdn = normalize_fqdn(asset.get(key, ""))
            if fqdn:
                return fqdn
    return ip


def rewrite_url_host(url: str, host: str) -> str:
    if not url:
        return ""
    parsed = urlsplit(url)
    if not parsed.scheme:
        return url
    port = f":{parsed.port}" if parsed.port else ""
    netloc = f"{host}{port}"
    path = parsed.path or "/"
    return urlunsplit((parsed.scheme, netloc, path, parsed.query, parsed.fragment))


def discover_web_apps(inventory: dict) -> dict:
    ip_assets = build_ip_assets_map(inventory)
    ips = collect_ips(inventory)
    if not ips:
        return {
            "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "total": 0,
            "reachable": 0,
            "items": [],
        }

    nmap_root = run_port_scan(ips)

    apps: list[dict] = []
    for host in nmap_root.findall("host"):
        status = host.find("status")
        if status is None or status.attrib.get("state") != "up":
            continue

        addr = host.find("address")
        if addr is None:
            continue
        ip = addr.attrib.get("addr", "")
        if not ip:
            continue

        for port in host.findall("ports/port"):
            state = port.find("state")
            if state is None or state.attrib.get("state") != "open":
                continue

            port_num = int(port.attrib.get("portid", "0"))
            if port_num not in WEB_PORTS:
                continue

            schemes = ["https", "http"] if port_num in {443, 8443} else ["http", "https"]
            best = None
            for scheme in schemes:
                candidate_url = f"{scheme}://{ip}:{port_num}/"
                result = fetch_url(candidate_url)
                if result["reachable"]:
                    best = (candidate_url, result)
                    break
                if best is None:
                    best = (candidate_url, result)

            if best is None:
                continue
            probe_url, result = best
            assets = ip_assets.get(ip, [])
            dns_name = display_dns_name(ip, port_num, assets)
            url = rewrite_url_host(probe_url, dns_name)
            final_url = rewrite_url_host(result["final_url"] or probe_url, dns_name)
            apps.append(
                {
                    "ip": ip,
                    "dns_name": dns_name,
                    "port": port_num,
                    "url": url,
                    "probe_url": probe_url,
                    "reachable": result["reachable"],
                    "status": result["status"],
                    "final_url": final_url,
                    "probe_final_url": result["final_url"],
                    "title": result["title"],
                    "server": result["server"],
                    "error": result["error"],
                    "assets": assets,
                }
            )

    apps.sort(key=lambda item: (item["ip"], item["port"]))
    return {
        "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total": len(apps),
        "reachable": sum(1 for item in apps if item["reachable"]),
        "items": apps,
    }


def main() -> int:
    inventory = load_inventory()
    payload = discover_web_apps(inventory)
    OUTPUT_JSON.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Wrote: {OUTPUT_JSON}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
