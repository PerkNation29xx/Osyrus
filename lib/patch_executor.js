"use strict";

const path = require("node:path");
const { spawn } = require("node:child_process");

const runningJobs = new Set();

function boolText(value) {
  return value === true ? "true" : "false";
}

function trimOutput(text, maxChars = 24000) {
  const value = String(text || "");
  if (value.length <= maxChars) {
    return value;
  }
  return `${value.slice(0, maxChars)}\n...[truncated ${value.length - maxChars} chars]`;
}

async function startPatchExecution({ job, store, rootDir, actor }) {
  const jobId = Number(job.id);
  if (runningJobs.has(jobId)) {
    throw new Error(`Patch job ${jobId} is already running`);
  }

  const plan = job.plan || {};
  const summary = plan.summary || {};
  const policy = plan.policy || {};

  const scriptPath = path.join(rootDir, "scripts", "patch", "run_ansible_patch.sh");
  const executionMode = process.env.OSYRUS_PATCH_EXECUTION_MODE || policy.execution_mode || "dry-run";
  const ansiblePlaybook = process.env.OSYRUS_PATCH_PLAYBOOK || policy.ansible_playbook || "ansible/playbooks/osyrus_patch_workflow.yml";
  const ansibleInventory = process.env.OSYRUS_PATCH_INVENTORY || policy.ansible_inventory || "ansible/inventory/hosts.ini";

  const startAt = new Date().toISOString();
  const runningExecution = {
    ...(job.execution || {}),
    mode: executionMode,
    started_at: startAt,
    completed_at: "",
    exit_code: null,
    output: "",
    command: `bash ${scriptPath}`,
  };

  await store.updateJob(
    jobId,
    {
      status: "running",
      executed_by: actor,
      execution: runningExecution,
      last_error: "",
    },
    actor,
    "execution_started",
    {
      mode: executionMode,
      ansible_playbook: ansiblePlaybook,
      ansible_inventory: ansibleInventory,
    },
  );

  runningJobs.add(jobId);

  const child = spawn("bash", [scriptPath], {
    cwd: rootDir,
    env: {
      ...process.env,
      JOB_ID: String(jobId),
      TARGET_IP: String(job.target_ip || ""),
      TARGET_NAME: String(job.target_name || ""),
      TARGET_TYPE: String(job.target_type || ""),
      HOST_ALIAS: String(job.host_alias || ""),
      CVE_ID: String(job.cve_id || ""),
      SNAPSHOT_REQUIRED: boolText(summary.snapshot_required === true),
      CLONE_VM: boolText(job.clone_requested === true),
      ROLLBACK_STRATEGY: String(summary.rollback_strategy || ""),
      ANSIBLE_PLAYBOOK: ansiblePlaybook,
      ANSIBLE_INVENTORY: ansibleInventory,
      EXECUTION_MODE: executionMode,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdoutBuffer = "";
  let stderrBuffer = "";

  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderrBuffer += chunk.toString();
  });

  child.on("error", async (error) => {
    const completedAt = new Date().toISOString();
    const execution = {
      ...runningExecution,
      completed_at: completedAt,
      exit_code: -1,
      output: trimOutput(`${stdoutBuffer}\n${stderrBuffer}\n${error.message}`),
    };
    await store.updateJob(
      jobId,
      {
        status: "failed",
        execution,
        last_error: error.message,
      },
      actor,
      "execution_failed",
      {
        message: error.message,
      },
    );
    runningJobs.delete(jobId);
  });

  child.on("close", async (code, signal) => {
    const completedAt = new Date().toISOString();
    const exitCode = Number.isFinite(code) ? Number(code) : -1;
    const success = exitCode === 0;
    const mergedOutput = `${stdoutBuffer}\n${stderrBuffer}${signal ? `\nSignal: ${signal}` : ""}`;

    const execution = {
      ...runningExecution,
      completed_at: completedAt,
      exit_code: exitCode,
      signal: signal || "",
      output: trimOutput(mergedOutput),
    };

    await store.updateJob(
      jobId,
      {
        status: success ? "completed" : "failed",
        execution,
        last_error: success ? "" : `Execution failed with exit code ${exitCode}`,
      },
      actor,
      success ? "execution_completed" : "execution_failed",
      {
        exit_code: exitCode,
        signal: signal || "",
      },
    );

    runningJobs.delete(jobId);
  });

  return {
    status: "running",
    started_at: startAt,
    mode: executionMode,
  };
}

module.exports = {
  startPatchExecution,
};
