"use strict";

function normalizeText(value) {
  const text = String(value || "").trim();
  return text.length > 0 ? text : "";
}

function boolFromValue(value) {
  if (typeof value === "boolean") {
    return value;
  }
  const normalized = String(value || "").toLowerCase();
  return ["1", "true", "yes", "on"].includes(normalized);
}

function buildAssetIndex(vulnerabilityPayload) {
  const byIp = new Map();
  for (const asset of vulnerabilityPayload?.assets || []) {
    const ip = normalizeText(asset.ip);
    if (!ip) {
      continue;
    }
    const list = byIp.get(ip) || [];
    list.push(asset);
    byIp.set(ip, list);
  }
  return byIp;
}

function inferSshAccessible(vulnerabilityAssets) {
  for (const asset of vulnerabilityAssets || []) {
    for (const service of asset.services || []) {
      if (Number(service.port) === 22) {
        return true;
      }
    }
  }
  return false;
}

function findTopCveForAsset(vulnerabilityAssets, cveId) {
  if (!Array.isArray(vulnerabilityAssets) || vulnerabilityAssets.length === 0) {
    return null;
  }

  if (cveId) {
    for (const asset of vulnerabilityAssets) {
      for (const cve of asset.cves || []) {
        if (String(cve.id || "").toUpperCase() === cveId.toUpperCase()) {
          return cve;
        }
      }
    }
  }

  let best = null;
  for (const asset of vulnerabilityAssets) {
    for (const cve of asset.cves || []) {
      if (!best) {
        best = cve;
        continue;
      }
      const bestScore = Number(best.score || 0);
      const score = Number(cve.score || 0);
      if (score > bestScore) {
        best = cve;
      }
    }
  }
  return best;
}

function resolveTargetContext({ targetIp, targetName, hostAlias }, inventoryPayload, vulnerabilityPayload) {
  const ip = normalizeText(targetIp);
  const name = normalizeText(targetName);
  const alias = normalizeText(hostAlias);

  const vulnAssetIndex = buildAssetIndex(vulnerabilityPayload);
  const vulnerabilityAssets = ip ? (vulnAssetIndex.get(ip) || []) : [];

  let context = {
    target_ip: ip,
    target_name: name || ip || "unknown-target",
    target_type: "unknown",
    host_alias: alias || "",
    vm_name: "",
    inventory_host_ip: "",
    inventory_host_alias: "",
    vulnerability_assets: vulnerabilityAssets,
    ssh_accessible: inferSshAccessible(vulnerabilityAssets),
  };

  for (const host of inventoryPayload?.hosts || []) {
    if (ip && host.ip === ip) {
      context = {
        ...context,
        target_name: context.target_name || host.alias || ip,
        target_type: "esxi_host",
        host_alias: host.alias || alias || "",
        inventory_host_ip: host.ip || "",
        inventory_host_alias: host.alias || "",
      };
      return context;
    }
  }

  for (const host of inventoryPayload?.hosts || []) {
    for (const vm of host.vms || []) {
      const vmIp = normalizeText(vm.guest_ip);
      const vmName = normalizeText(vm.name);
      const ipMatch = ip && vmIp === ip;
      const nameMatch = name && vmName && vmName.toLowerCase() === name.toLowerCase();
      if (!ipMatch && !nameMatch) {
        continue;
      }

      context = {
        ...context,
        target_ip: ip || vmIp,
        target_name: vmName || context.target_name,
        target_type: "vm_guest",
        host_alias: host.alias || alias || "",
        vm_name: vmName || "",
        inventory_host_ip: host.ip || "",
        inventory_host_alias: host.alias || "",
        vulnerability_assets: vmIp ? (vulnAssetIndex.get(vmIp) || vulnerabilityAssets) : vulnerabilityAssets,
      };
      return context;
    }
  }

  if (vulnerabilityAssets.length > 0) {
    const first = vulnerabilityAssets[0];
    const assetType = normalizeText(first.asset_type) || "network_asset";
    context = {
      ...context,
      target_type: assetType,
      target_name: normalizeText(first.asset_name) || context.target_name,
      host_alias: normalizeText(first.host_alias) || context.host_alias,
    };
  }

  return context;
}

function buildBackupPlan(context, cloneRequested) {
  const backupActions = [];
  let rollbackStrategy = "manual_restore_required";
  let alertRequired = false;
  const alerts = [];

  const vmCapable = context.target_type === "vm_guest" && Boolean(context.vm_name);
  const sshCapable = context.ssh_accessible === true;

  if (vmCapable) {
    backupActions.push({
      id: "vm_snapshot",
      type: "snapshot",
      required: true,
      description: "Create hypervisor snapshot before patch execution.",
    });
    rollbackStrategy = "revert_vm_snapshot";

    if (cloneRequested) {
      backupActions.push({
        id: "vm_clone",
        type: "clone",
        required: false,
        description: "Clone VM before patch execution for side-by-side rollback validation.",
      });
    }
  } else if (sshCapable) {
    backupActions.push({
      id: "package_state_capture",
      type: "package-state",
      required: true,
      description: "Capture package/version state before patching for downgrade rollback.",
    });
    rollbackStrategy = "package_downgrade_or_version_pin";
    if (cloneRequested) {
      alerts.push("Clone requested but target is not a VM. Clone action skipped.");
    }
  } else {
    alertRequired = true;
    rollbackStrategy = "no_automated_rollback";
    alerts.push("No VM snapshot path and no SSH/package rollback path detected.");
    alerts.push("User acknowledgement is required before execution.");
  }

  return {
    backup_actions: backupActions,
    rollback_strategy: rollbackStrategy,
    alert_required: alertRequired,
    alerts,
  };
}

function buildPatchPlan(input, inventoryPayload, vulnerabilityPayload) {
  const targetIp = normalizeText(input.target_ip || input.ip);
  const targetName = normalizeText(input.target_name || input.name);
  const hostAlias = normalizeText(input.host_alias);
  const cveId = normalizeText(input.cve_id).toUpperCase();
  const cloneRequested = boolFromValue(input.clone_vm);

  const context = resolveTargetContext(
    { targetIp, targetName, hostAlias },
    inventoryPayload || {},
    vulnerabilityPayload || {},
  );

  const cve = findTopCveForAsset(context.vulnerability_assets, cveId);
  const backup = buildBackupPlan(context, cloneRequested);
  const snapshotRequired = backup.backup_actions.some((item) => item.id === "vm_snapshot");
  const cloneEnabled = backup.backup_actions.some((item) => item.id === "vm_clone");

  const policy = {
    approval_required: true,
    auto_block_without_backup: true,
    execution_mode: process.env.OSYRUS_PATCH_EXECUTION_MODE || "dry-run",
    ansible_playbook: process.env.OSYRUS_PATCH_PLAYBOOK || "ansible/playbooks/osyrus_patch_workflow.yml",
    ansible_inventory: process.env.OSYRUS_PATCH_INVENTORY || "ansible/inventory/hosts.ini",
  };

  const summary = {
    target_ip: context.target_ip || targetIp,
    target_name: context.target_name || targetName || targetIp || "unknown-target",
    target_type: context.target_type,
    host_alias: context.host_alias || hostAlias || "",
    inventory_host_alias: context.inventory_host_alias || "",
    inventory_host_ip: context.inventory_host_ip || "",
    vm_name: context.vm_name || "",
    ssh_accessible: context.ssh_accessible === true,
    snapshot_required: snapshotRequired,
    clone_requested: cloneRequested,
    clone_enabled: cloneEnabled,
    rollback_strategy: backup.rollback_strategy,
    backup_actions: backup.backup_actions,
    alert_required: backup.alert_required,
    alerts: backup.alerts,
    cve: cve
      ? {
          id: cve.id || cveId || "",
          score: Number(cve.score || 0),
          severity: cve.severity || "info",
          url: cve.url || "",
        }
      : {
          id: cveId || "",
          score: 0,
          severity: "unknown",
          url: "",
        },
  };

  return {
    created_at: new Date().toISOString(),
    policy,
    summary,
  };
}

module.exports = {
  buildPatchPlan,
};
