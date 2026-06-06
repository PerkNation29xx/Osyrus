#!/usr/bin/env python3
"""Collect Osyrus web HA and MariaDB replication health.

Outputs two artifacts:
- ha_status.json for the Osyrus portal/Supabase snapshot pipeline
- osyrus_web_ha.prom for Prometheus node_exporter textfile collection
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import socket
import ssl
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_PORTAL_JSON = Path.home() / "Documents/New project/osyrus-portal/ha_status.json"
DEFAULT_METRICS_FILE = Path.home() / "homebrew/var/node_exporter/textfile_collector/osyrus_web_ha.prom"
DEFAULT_SSH_KEY = Path.home() / ".ssh/osyrus_ops"
DEFAULT_TIMEOUT = 8
DEFAULT_WORKERS = 12
VIP = "192.168.12.163"
PUBLIC_IP = "47.51.26.76"

SERVICES = ["haproxy", "keepalived", "nginx", "php8.3-fpm", "mariadb"]

NODES = [
    {
        "name": "neonflux-chat-vm1",
        "ip": "192.168.12.161",
        "role": "primary",
        "ssh_user": "neonflux",
        "expected_vip_owner": True,
        "db_role": "primary",
    },
    {
        "name": "neonflux-chat-vm2",
        "ip": "192.168.12.162",
        "role": "standby",
        "ssh_user": "neonflux",
        "expected_vip_owner": False,
        "db_role": "replica",
    },
]

SITES = [
    {"name": "Medallo Music", "domain": "medallomusic.com", "backend": "be_wp_medallo", "port": 8080, "path": "/"},
    {"name": "The Unity Logistics", "domain": "theunitylogistics.com", "backend": "be_wp_unity", "port": 8081, "path": "/"},
    {"name": "Gilly Loco Distro", "domain": "gillylocodistro.com", "backend": "be_wp_gilly", "port": 8082, "path": "/"},
    {"name": "NeonFlux", "domain": "neonflux.co", "backend": "be_wp_neonflux", "port": 8083, "path": "/"},
    {"name": "Cheros de la Selecta", "domain": "cherosdelaselecta.com", "backend": "be_wp_cheros", "port": 8084, "path": "/"},
    {"name": "La Selecta Fan Club", "domain": "laselectafanclub.cannacoin.website", "backend": "be_wp_cheros", "port": 8084, "path": "/"},
    {"name": "Miguel Huertas", "domain": "miguelhuertas.com", "backend": "be_wp_miguel", "port": 8085, "path": "/"},
    {"name": "CannaCoin", "domain": "cannacoin.website", "backend": "be_wp_cannacoin", "port": 8086, "path": "/"},
    {"name": "Carlos Yorvick", "domain": "carlosyorvick.com", "backend": "be_wp_carlos", "port": 8087, "path": "/"},
    {"name": "Asset Reduction", "domain": "assetreduction.com", "backend": "be_wp_assetreduction", "port": 8088, "path": "/"},
    {"name": "CannaTek", "domain": "cannatek.co", "backend": "be_mars", "port": 8089, "path": "/"},
    {"name": "Mars Hub", "domain": "mars.neonflux.co", "backend": "be_marshub", "port": 8090, "path": "/"},
]

VIP_CHECK_DOMAINS = [
    "medallomusic.com",
    "theunitylogistics.com",
    "neonflux.co",
    "assetreduction.com",
    "cannatek.co",
    "mars.neonflux.co",
]


@dataclass
class CommandResult:
    ok: bool
    stdout: str
    stderr: str
    returncode: int


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect Osyrus web HA status and Prometheus metrics.")
    parser.add_argument("--json-out", default=os.environ.get("WEB_HA_STATUS_JSON", str(DEFAULT_PORTAL_JSON)))
    parser.add_argument("--metrics-out", default=os.environ.get("WEB_HA_METRICS_FILE", str(DEFAULT_METRICS_FILE)))
    parser.add_argument("--ssh-key", default=os.environ.get("WEB_HA_SSH_KEY", str(DEFAULT_SSH_KEY)))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("WEB_HA_TIMEOUT_SEC", DEFAULT_TIMEOUT)))
    parser.add_argument("--workers", type=int, default=int(os.environ.get("WEB_HA_WORKERS", DEFAULT_WORKERS)))
    parser.add_argument("--skip-site-checks", action="store_true", default=os.environ.get("WEB_HA_SKIP_SITE_CHECKS", "").lower() in {"1", "true", "yes"})
    return parser.parse_args()


def run_command(cmd: list[str], timeout: float) -> CommandResult:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return CommandResult(result.returncode == 0, result.stdout, result.stderr, result.returncode)
    except subprocess.TimeoutExpired as error:
        return CommandResult(False, error.stdout or "", error.stderr or f"timeout after {timeout}s", 124)
    except OSError as error:
        return CommandResult(False, "", str(error), 127)


def ssh_run(node: dict[str, Any], command: str, ssh_key: Path, timeout: float) -> CommandResult:
    ssh_cmd = [
        "ssh",
        "-i",
        str(ssh_key),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        f"ConnectTimeout={max(1, int(timeout))}",
        "-o",
        "ServerAliveInterval=5",
        "-o",
        "ServerAliveCountMax=1",
        f"{node['ssh_user']}@{node['ip']}",
        command,
    ]
    return run_command(ssh_cmd, timeout + 4)


def parse_service_output(raw: str) -> dict[str, str]:
    services: dict[str, str] = {}
    for line in raw.splitlines():
        if "\t" not in line:
            continue
        service, state = line.split("\t", 1)
        services[service.strip()] = state.strip() or "unknown"
    return services


def parse_key_value_lines(raw: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in raw.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def parse_mysql_vertical(raw: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip()
    return values


def collect_node(node: dict[str, Any], ssh_key: Path, timeout: float) -> dict[str, Any]:
    service_command = "for s in haproxy keepalived nginx php8.3-fpm mariadb; do state=$(systemctl is-active \"$s\" 2>/dev/null || true); printf '%s\\t%s\\n' \"$s\" \"$state\"; done"
    service_result = ssh_run(node, service_command, ssh_key, timeout)
    services = parse_service_output(service_result.stdout)

    vip_command = f"ip -o -4 addr show | awk '{{print $4}}' | grep -qx '{VIP}/24' && echo 1 || echo 0"
    vip_result = ssh_run(node, vip_command, ssh_key, timeout)
    vip_owned = vip_result.stdout.strip().splitlines()[-1:] == ["1"]

    db_base_command = "sudo -n mysql -NBe \"SELECT CONCAT('hostname=', @@hostname); SELECT CONCAT('server_id=', @@global.server_id); SELECT CONCAT('read_only=', @@global.read_only); SELECT CONCAT('log_bin=', @@global.log_bin);\""
    db_base_result = ssh_run(node, db_base_command, ssh_key, timeout)
    db_values = parse_key_value_lines(db_base_result.stdout)

    db_info: dict[str, Any] = {
        "role": node["db_role"],
        "admin_access_verified": db_base_result.ok,
        "hostname": db_values.get("hostname", ""),
        "server_id": to_int(db_values.get("server_id")),
        "read_only": to_bool_int(db_values.get("read_only")),
        "log_bin": to_bool_int(db_values.get("log_bin")),
        "error": clean_error(db_base_result.stderr) if not db_base_result.ok else "",
    }

    if node["db_role"] == "primary":
        master_result = ssh_run(node, "sudo -n mysql -Be \"SHOW MASTER STATUS\\\\G\"", ssh_key, timeout)
        master = parse_mysql_vertical(master_result.stdout)
        db_info.update(
            {
                "master_status_accessible": master_result.ok,
                "binlog_file": master.get("File", ""),
                "binlog_position": to_int(master.get("Position")),
                "master_error": clean_error(master_result.stderr) if not master_result.ok else "",
            }
        )
    else:
        slave_result = ssh_run(node, "sudo -n mysql -Be \"SHOW SLAVE STATUS\\\\G\"", ssh_key, timeout)
        slave = parse_mysql_vertical(slave_result.stdout)
        io_running = slave.get("Slave_IO_Running") == "Yes"
        sql_running = slave.get("Slave_SQL_Running") == "Yes"
        lag = to_int(slave.get("Seconds_Behind_Master"), default=-1)
        db_info.update(
            {
                "replication_status_accessible": slave_result.ok,
                "master_host": slave.get("Master_Host", ""),
                "master_server_id": to_int(slave.get("Master_Server_Id")),
                "slave_io_running": io_running,
                "slave_sql_running": sql_running,
                "seconds_behind_master": lag,
                "read_master_log_pos": to_int(slave.get("Read_Master_Log_Pos")),
                "exec_master_log_pos": to_int(slave.get("Exec_Master_Log_Pos")),
                "last_io_errno": to_int(slave.get("Last_IO_Errno")),
                "last_sql_errno": to_int(slave.get("Last_SQL_Errno")),
                "last_io_error": slave.get("Last_IO_Error", ""),
                "last_sql_error": slave.get("Last_SQL_Error", ""),
                "slave_sql_running_state": slave.get("Slave_SQL_Running_State", ""),
                "replication_healthy": slave_result.ok and io_running and sql_running and lag >= 0 and lag <= 30,
                "replication_error": clean_error(slave_result.stderr) if not slave_result.ok else "",
            }
        )

    services_active = all(services.get(service) == "active" for service in SERVICES)
    return {
        "name": node["name"],
        "ip": node["ip"],
        "role": node["role"],
        "db_role": node["db_role"],
        "reachable": service_result.ok,
        "vip_owned": vip_owned,
        "expected_vip_owner": node["expected_vip_owner"],
        "services": {service: services.get(service, "unknown") for service in SERVICES},
        "services_healthy": service_result.ok and services_active,
        "db": db_info,
    }


def to_int(raw: Any, default: int = 0) -> int:
    try:
        if raw in (None, "", "NULL"):
            return default
        return int(str(raw).strip())
    except (TypeError, ValueError):
        return default


def to_bool_int(raw: Any) -> bool:
    value = str(raw or "").strip().lower()
    if value in {"1", "on", "yes", "true"}:
        return True
    if value in {"0", "off", "no", "false"}:
        return False
    return to_int(raw) == 1


def clean_error(raw: str) -> str:
    return " ".join((raw or "").strip().split())[:500]


def http_probe(host: str, port: int, domain: str, path: str, timeout: float, use_https: bool = False) -> dict[str, Any]:
    started = time.monotonic()
    conn: http.client.HTTPConnection | None = None
    try:
        if use_https:
            context = ssl._create_unverified_context()
            conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=context)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("GET", path, headers={"Host": domain, "User-Agent": "osyrus-ha-monitor/1.0"})
        response = conn.getresponse()
        status_code = int(response.status)
        conn.close()
        elapsed = time.monotonic() - started
        healthy = 200 <= status_code < 500
        return {
            "healthy": healthy,
            "status_code": status_code,
            "response_seconds": round(elapsed, 3),
            "error": "",
        }
    except (OSError, TimeoutError, ssl.SSLError, http.client.HTTPException) as error:
        elapsed = time.monotonic() - started
        return {
            "healthy": False,
            "status_code": 0,
            "response_seconds": round(elapsed, 3),
            "error": str(error)[:300],
        }
    finally:
        if conn is not None:
            conn.close()


def collect_site_checks(timeout: float, workers: int) -> list[dict[str, Any]]:
    sites_by_domain: dict[str, dict[str, Any]] = {
        site["domain"]: {**site, "checks": []}
        for site in SITES
    }
    futures = {}
    with ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        for site in SITES:
            for node in NODES:
                future = executor.submit(http_probe, node["ip"], int(site["port"]), site["domain"], site["path"], timeout, False)
                futures[future] = (site, node)

        for future in as_completed(futures):
            site, node = futures[future]
            probe = future.result()
            sites_by_domain[site["domain"]]["checks"].append(
                {
                    "node": node["name"],
                    "ip": node["ip"],
                    "role": node["role"],
                    "port": site["port"],
                    **probe,
                }
            )

    sites: list[dict[str, Any]] = []
    for site in SITES:
        item = sites_by_domain[site["domain"]]
        item["checks"].sort(key=lambda check: (check.get("role") != "primary", check.get("node", "")))
        sites.append(item)
    return sites


def collect_haproxy_checks(timeout: float, workers: int) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    futures = {}
    with ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        for domain in VIP_CHECK_DOMAINS:
            for target in [*NODES, {"name": "wordpress-vip", "ip": VIP, "role": "vip"}]:
                future = executor.submit(http_probe, target["ip"], 443, domain, "/", timeout, True)
                futures[future] = (domain, target)

        for future in as_completed(futures):
            domain, target = futures[future]
            probe = future.result()
            checks.append(
                {
                    "domain": domain,
                    "target": target["name"],
                    "ip": target["ip"],
                    "role": target["role"],
                    **probe,
                }
            )

    checks.sort(key=lambda check: (check.get("domain", ""), check.get("role", ""), check.get("target", "")))
    return checks


def build_summary(nodes: list[dict[str, Any]], sites: list[dict[str, Any]], haproxy_checks: list[dict[str, Any]]) -> dict[str, Any]:
    vip_owner_nodes = [node for node in nodes if node.get("vip_owned")]
    replica = next((node for node in nodes if node.get("db_role") == "replica"), None)
    primary = next((node for node in nodes if node.get("db_role") == "primary"), None)

    site_checks = [check for site in sites for check in site.get("checks", [])]
    healthy_site_checks = sum(1 for check in site_checks if check.get("healthy"))
    healthy_haproxy_checks = sum(1 for check in haproxy_checks if check.get("healthy"))

    services_healthy = all(node.get("services_healthy") for node in nodes)
    vip_healthy = len(vip_owner_nodes) == 1 and vip_owner_nodes[0].get("role") == "primary"
    primary_db_ok = bool(primary and primary.get("db", {}).get("admin_access_verified") and primary.get("db", {}).get("read_only") is False)
    replica_db = replica.get("db", {}) if replica else {}
    replica_db_ok = bool(replica_db.get("replication_healthy") and replica_db.get("read_only") is True)
    sites_healthy = healthy_site_checks == len(site_checks) if site_checks else True
    haproxy_healthy = healthy_haproxy_checks == len(haproxy_checks) if haproxy_checks else True

    overall_healthy = all([services_healthy, vip_healthy, primary_db_ok, replica_db_ok, sites_healthy, haproxy_healthy])
    status = "healthy" if overall_healthy else "degraded"

    cautions = [
        "Database promotion is manual by design to avoid split-brain.",
        "Replica is read-only; write/admin failover requires controlled promotion.",
    ]
    if not services_healthy:
        cautions.append("One or more HA services are not active.")
    if not vip_healthy:
        cautions.append("VIP owner is not the expected primary node or owner count is not exactly one.")
    if not replica_db_ok:
        cautions.append("MariaDB replica health is degraded or lag is above threshold.")
    if not sites_healthy:
        cautions.append("One or more direct backend site checks failed.")
    if not haproxy_healthy:
        cautions.append("One or more HAProxy HTTPS checks failed.")

    return {
        "overall_status": status,
        "overall_healthy": overall_healthy,
        "vip": VIP,
        "public_ip": PUBLIC_IP,
        "active_vip_node": vip_owner_nodes[0]["name"] if len(vip_owner_nodes) == 1 else "unknown",
        "vip_owner_count": len(vip_owner_nodes),
        "services_healthy": services_healthy,
        "db_primary_read_write": primary_db_ok,
        "db_replica_read_only": replica_db.get("read_only") is True,
        "db_replication_healthy": replica_db_ok,
        "db_seconds_behind_master": replica_db.get("seconds_behind_master", -1),
        "site_backend_checks_total": len(site_checks),
        "site_backend_checks_healthy": healthy_site_checks,
        "haproxy_checks_total": len(haproxy_checks),
        "haproxy_checks_healthy": healthy_haproxy_checks,
        "cautions": cautions,
    }


def prom_escape(value: Any) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def metric_line(name: str, value: int | float, labels: dict[str, Any] | None = None) -> str:
    if labels:
        label_text = ",".join(f'{key}="{prom_escape(val)}"' for key, val in sorted(labels.items()))
        return f"{name}{{{label_text}}} {value}"
    return f"{name} {value}"


def bool_metric(value: Any) -> int:
    return 1 if bool(value) else 0


def build_metrics(payload: dict[str, Any], collect_success: int) -> list[str]:
    summary = payload.get("summary", {})
    lines = [
        "# HELP osyrus_web_ha_collect_success Whether the HA collector completed successfully.",
        "# TYPE osyrus_web_ha_collect_success gauge",
        metric_line("osyrus_web_ha_collect_success", collect_success),
        "# HELP osyrus_web_ha_last_run_timestamp_seconds Unix timestamp of the latest HA collection.",
        "# TYPE osyrus_web_ha_last_run_timestamp_seconds gauge",
        metric_line("osyrus_web_ha_last_run_timestamp_seconds", int(time.time())),
        "# HELP osyrus_web_ha_summary_healthy Overall HA health summary, 1 healthy and 0 degraded.",
        "# TYPE osyrus_web_ha_summary_healthy gauge",
        metric_line("osyrus_web_ha_summary_healthy", bool_metric(summary.get("overall_healthy"))),
        "# HELP osyrus_web_ha_vip_owner_count Count of nodes currently owning the web VIP.",
        "# TYPE osyrus_web_ha_vip_owner_count gauge",
        metric_line("osyrus_web_ha_vip_owner_count", int(summary.get("vip_owner_count", 0))),
        "# HELP osyrus_web_ha_site_backend_checks_total Total direct backend site checks.",
        "# TYPE osyrus_web_ha_site_backend_checks_total gauge",
        metric_line("osyrus_web_ha_site_backend_checks_total", int(summary.get("site_backend_checks_total", 0))),
        "# HELP osyrus_web_ha_site_backend_checks_healthy Healthy direct backend site checks.",
        "# TYPE osyrus_web_ha_site_backend_checks_healthy gauge",
        metric_line("osyrus_web_ha_site_backend_checks_healthy", int(summary.get("site_backend_checks_healthy", 0))),
        "# HELP osyrus_web_ha_haproxy_checks_total Total HTTPS HAProxy checks.",
        "# TYPE osyrus_web_ha_haproxy_checks_total gauge",
        metric_line("osyrus_web_ha_haproxy_checks_total", int(summary.get("haproxy_checks_total", 0))),
        "# HELP osyrus_web_ha_haproxy_checks_healthy Healthy HTTPS HAProxy checks.",
        "# TYPE osyrus_web_ha_haproxy_checks_healthy gauge",
        metric_line("osyrus_web_ha_haproxy_checks_healthy", int(summary.get("haproxy_checks_healthy", 0))),
        "# HELP osyrus_web_ha_node_reachable SSH/systemd reachability by node.",
        "# TYPE osyrus_web_ha_node_reachable gauge",
    ]

    for node in payload.get("nodes", []):
        node_labels = {"node": node.get("name"), "ip": node.get("ip"), "role": node.get("role")}
        lines.append(metric_line("osyrus_web_ha_node_reachable", bool_metric(node.get("reachable")), node_labels))
        lines.append(metric_line("osyrus_web_ha_vip_owned", bool_metric(node.get("vip_owned")), node_labels))
        lines.append(metric_line("osyrus_web_ha_services_healthy", bool_metric(node.get("services_healthy")), node_labels))
        for service, state in node.get("services", {}).items():
            lines.append(metric_line("osyrus_web_ha_service_active", 1 if state == "active" else 0, {**node_labels, "service": service}))

        db = node.get("db", {})
        db_labels = {**node_labels, "db_role": node.get("db_role", "")}
        lines.append(metric_line("osyrus_web_ha_db_admin_access_verified", bool_metric(db.get("admin_access_verified")), db_labels))
        lines.append(metric_line("osyrus_web_ha_db_read_only", bool_metric(db.get("read_only")), db_labels))
        lines.append(metric_line("osyrus_web_ha_db_log_bin_enabled", bool_metric(db.get("log_bin")), db_labels))
        if node.get("db_role") == "replica":
            lines.append(metric_line("osyrus_web_ha_db_replication_healthy", bool_metric(db.get("replication_healthy")), db_labels))
            lines.append(metric_line("osyrus_web_ha_db_seconds_behind_master", int(db.get("seconds_behind_master", -1)), db_labels))
            lines.append(metric_line("osyrus_web_ha_db_replication_thread_running", bool_metric(db.get("slave_io_running")), {**db_labels, "thread": "io"}))
            lines.append(metric_line("osyrus_web_ha_db_replication_thread_running", bool_metric(db.get("slave_sql_running")), {**db_labels, "thread": "sql"}))

    lines.extend(
        [
            "# HELP osyrus_web_ha_site_backend_healthy Direct backend site health by node and port.",
            "# TYPE osyrus_web_ha_site_backend_healthy gauge",
        ]
    )
    for site in payload.get("sites", []):
        for check in site.get("checks", []):
            labels = {
                "site": site.get("domain"),
                "backend": site.get("backend"),
                "node": check.get("node"),
                "ip": check.get("ip"),
                "role": check.get("role"),
                "port": check.get("port"),
            }
            lines.append(metric_line("osyrus_web_ha_site_backend_healthy", bool_metric(check.get("healthy")), labels))
            lines.append(metric_line("osyrus_web_ha_site_backend_http_status", int(check.get("status_code", 0)), labels))
            lines.append(metric_line("osyrus_web_ha_site_backend_response_seconds", float(check.get("response_seconds", 0)), labels))

    lines.extend(
        [
            "# HELP osyrus_web_ha_haproxy_https_healthy HTTPS health through HAProxy target.",
            "# TYPE osyrus_web_ha_haproxy_https_healthy gauge",
        ]
    )
    for check in payload.get("haproxy_checks", []):
        labels = {
            "site": check.get("domain"),
            "target": check.get("target"),
            "ip": check.get("ip"),
            "role": check.get("role"),
        }
        lines.append(metric_line("osyrus_web_ha_haproxy_https_healthy", bool_metric(check.get("healthy")), labels))
        lines.append(metric_line("osyrus_web_ha_haproxy_https_status", int(check.get("status_code", 0)), labels))
        lines.append(metric_line("osyrus_web_ha_haproxy_https_response_seconds", float(check.get("response_seconds", 0)), labels))

    return lines


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(f"{path.suffix}.tmp")
    tmp_path.write_text(text, encoding="utf-8")
    tmp_path.replace(path)


def main() -> int:
    args = parse_args()
    ssh_key = Path(args.ssh_key).expanduser()
    timeout = max(1.0, float(args.timeout))
    workers = max(1, int(args.workers))
    json_out = Path(args.json_out).expanduser()
    metrics_out = Path(args.metrics_out).expanduser()

    collect_success = 1
    errors: list[str] = []

    nodes: list[dict[str, Any]] = []
    try:
        nodes = [collect_node(node, ssh_key, timeout) for node in NODES]
    except Exception as error:  # noqa: BLE001 - collector should emit degraded metrics instead of crashing.
        collect_success = 0
        errors.append(f"node collection failed: {error}")

    sites: list[dict[str, Any]] = []
    haproxy_checks: list[dict[str, Any]] = []
    if not args.skip_site_checks:
        try:
            sites = collect_site_checks(timeout, workers)
            haproxy_checks = collect_haproxy_checks(timeout, workers)
        except Exception as error:  # noqa: BLE001
            collect_success = 0
            errors.append(f"site checks failed: {error}")

    summary = build_summary(nodes, sites, haproxy_checks)
    payload = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "source": "scripts/recovery/collect_web_ha_metrics.py",
        "summary": summary,
        "topology": {
            "vip": VIP,
            "public_ip": PUBLIC_IP,
            "model": "active/passive web HA with manual DB promotion",
            "shared_content": "192.168.12.170:/mac-spark mounted at /srv/neonflux/shared",
            "primary_node": "192.168.12.161",
            "standby_node": "192.168.12.162",
        },
        "credential_references": {
            "secrets_included": False,
            "db_admin_credentials_stored": True,
            "master_credential_index_stored": True,
            "ssh_key_registered": True,
        },
        "grafana": {
            "dashboard_uid": "osyrus-web-ha-db",
            "dashboard_url": "http://grafana.homelab.arpa:3000/d/osyrus-web-ha-db/osyrus-web-ha-and-db-replication",
            "metrics_file": str(metrics_out),
        },
        "nodes": nodes,
        "sites": sites,
        "haproxy_checks": haproxy_checks,
        "errors": errors,
    }

    metrics = build_metrics(payload, collect_success)
    atomic_write_text(json_out, json.dumps(payload, indent=2) + "\n")
    atomic_write_text(metrics_out, "\n".join(metrics) + "\n")
    print(f"wrote {json_out}")
    print(f"wrote {metrics_out}")
    print(f"overall_status={summary.get('overall_status')} db_replication_healthy={summary.get('db_replication_healthy')} backend_checks={summary.get('site_backend_checks_healthy')}/{summary.get('site_backend_checks_total')}")
    return 0 if collect_success else 1


if __name__ == "__main__":
    socket.setdefaulttimeout(DEFAULT_TIMEOUT)
    raise SystemExit(main())
