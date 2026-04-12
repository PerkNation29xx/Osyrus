"use strict";

const DATASET_REGISTRY = [
  { name: "inventory", route: "/inventory.json", file: "inventory.json" },
  { name: "vulnerability_report", route: "/vulnerability_report.json", file: "vulnerability_report.json" },
  { name: "scanner_nodes", route: "/scanner_nodes.json", file: "scanner_nodes.json" },
  { name: "web_apps_inventory", route: "/web_apps_inventory.json", file: "web_apps_inventory.json" },
  { name: "discovered_hosts", route: "/discovered_hosts.json", file: "discovered_hosts.json" },
  { name: "security_stack_inventory", route: "/security_stack_inventory.json", file: "security_stack_inventory.json" },
  { name: "app_inventory", route: "/app_inventory.json", file: "app_inventory.json" },
  { name: "remediation_status", route: "/remediation_status.json", file: "remediation_status.json" },
];

const ROUTE_TO_DATASET = new Map(DATASET_REGISTRY.map((item) => [item.route, item]));
const NAME_TO_DATASET = new Map(DATASET_REGISTRY.map((item) => [item.name, item]));

module.exports = {
  DATASET_REGISTRY,
  ROUTE_TO_DATASET,
  NAME_TO_DATASET,
};
