const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");

const { ROUTE_TO_DATASET } = require("./lib/datasets");
const { hasDatabase, query } = require("./lib/db");
const { resolveDatasetPayload } = require("./lib/snapshot_store");
const { buildPatchPlan } = require("./lib/patch_workflow");
const { createPatchStore } = require("./lib/patch_store");
const { startPatchExecution } = require("./lib/patch_executor");

const rootDir = __dirname;
const port = Number(process.env.PORT || 8090);
const dbRequired = ["1", "true", "yes", "on"].includes(String(process.env.PORTAL_DB_REQUIRED || "").toLowerCase());
const autoImportSetting = process.env.PORTAL_DB_AUTO_IMPORT;
const autoImport = autoImportSetting == null
  ? true
  : ["1", "true", "yes", "on"].includes(String(autoImportSetting).toLowerCase());
const patchStore = createPatchStore({ rootDir });

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
};

function send(res, statusCode, body, contentType = "text/plain; charset=utf-8", extraHeaders = {}) {
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
    ...extraHeaders,
  });
  res.end(body);
}

function sendHead(res, statusCode, contentType, extraHeaders = {}) {
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
    ...extraHeaders,
  });
  res.end();
}

function sendJson(res, statusCode, payload, extraHeaders = {}) {
  send(
    res,
    statusCode,
    `${JSON.stringify(payload, null, 2)}\n`,
    contentTypes[".json"],
    extraHeaders,
  );
}

async function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk.toString();
      if (raw.length > 1024 * 1024) {
        reject(new Error("Request body too large"));
      }
    });
    req.on("end", () => {
      if (raw.trim().length === 0) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (_error) {
        reject(new Error("Invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function getPatchConfiguredToken(role) {
  const globalToken = process.env.OSYRUS_PATCH_TOKEN || "";
  const roleEnvName = {
    request: "OSYRUS_PATCH_REQUEST_TOKEN",
    approve: "OSYRUS_PATCH_APPROVE_TOKEN",
    execute: "OSYRUS_PATCH_EXECUTE_TOKEN",
  }[role];
  const roleToken = roleEnvName ? (process.env[roleEnvName] || "") : "";
  return roleToken || globalToken || "";
}

function getProvidedToken(req) {
  const headerToken = String(req.headers["x-osyrus-token"] || "").trim();
  if (headerToken) {
    return headerToken;
  }
  const authHeader = String(req.headers.authorization || "").trim();
  if (authHeader.toLowerCase().startsWith("bearer ")) {
    return authHeader.slice(7).trim();
  }
  return "";
}

function extractActor(req, body, fallback = "portal-user") {
  const fromHeader = String(req.headers["x-osyrus-user"] || "").trim();
  const fromBody = String(body?.requested_by || body?.approved_by || body?.executed_by || "").trim();
  return fromHeader || fromBody || fallback;
}

function authorizePatchMutation(req, role) {
  const expectedToken = getPatchConfiguredToken(role);
  if (!expectedToken) {
    return {
      ok: false,
      statusCode: 503,
      message: "Patch workflow token is not configured on server",
    };
  }
  const providedToken = getProvidedToken(req);
  if (!providedToken || providedToken !== expectedToken) {
    return {
      ok: false,
      statusCode: 403,
      message: `Forbidden: invalid token for patch ${role} action`,
    };
  }
  return {
    ok: true,
    statusCode: 200,
    message: "authorized",
  };
}

function parsePositiveInt(value, fallback, maxValue = 500) {
  const parsed = Number.parseInt(String(value || ""), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.min(parsed, maxValue);
}

async function loadPatchPlanningPayloads() {
  const [inventory, vulnerability] = await Promise.all([
    resolveDatasetPayload("inventory", {
      rootDir,
      autoImport,
      strictDatabase: dbRequired,
    }),
    resolveDatasetPayload("vulnerability_report", {
      rootDir,
      autoImport,
      strictDatabase: dbRequired,
    }),
  ]);
  return {
    inventory: inventory?.payload || {},
    vulnerability: vulnerability?.payload || {},
  };
}

async function maybeServePatchApi(req, parsed, pathname, method, res) {
  if (!pathname.startsWith("/api/patch")) {
    return false;
  }

  if (pathname === "/api/patch/config") {
    if (!["GET", "HEAD"].includes(method)) {
      send(res, 405, "Method Not Allowed");
      return true;
    }

    const payload = {
      execution_mode: process.env.OSYRUS_PATCH_EXECUTION_MODE || "dry-run",
      ansible_playbook: process.env.OSYRUS_PATCH_PLAYBOOK || "ansible/playbooks/osyrus_patch_workflow.yml",
      ansible_inventory: process.env.OSYRUS_PATCH_INVENTORY || "ansible/inventory/hosts.ini",
      token_configured: {
        request: Boolean(getPatchConfiguredToken("request")),
        approve: Boolean(getPatchConfiguredToken("approve")),
        execute: Boolean(getPatchConfiguredToken("execute")),
      },
      timestamp: new Date().toISOString(),
    };

    if (method === "HEAD") {
      sendHead(res, 200, contentTypes[".json"]);
      return true;
    }
    sendJson(res, 200, payload);
    return true;
  }

  if (pathname === "/api/patch/jobs" && method === "GET") {
    const limit = parsePositiveInt(parsed.searchParams.get("limit"), 100, 500);
    const jobs = await patchStore.listJobs(limit);
    sendJson(res, 200, jobs);
    return true;
  }

  if (pathname === "/api/patch/jobs" && method === "HEAD") {
    sendHead(res, 200, contentTypes[".json"]);
    return true;
  }

  if (pathname === "/api/patch/plan" && method === "POST") {
    const body = await readJsonBody(req);
    const { inventory, vulnerability } = await loadPatchPlanningPayloads();
    const plan = buildPatchPlan(body || {}, inventory, vulnerability);
    sendJson(res, 200, plan);
    return true;
  }

  if (pathname === "/api/patch/jobs" && method === "POST") {
    const auth = authorizePatchMutation(req, "request");
    if (!auth.ok) {
      sendJson(res, auth.statusCode, { error: auth.message });
      return true;
    }

    const body = await readJsonBody(req);
    const actor = extractActor(req, body, "requester");
    const { inventory, vulnerability } = await loadPatchPlanningPayloads();
    const plan = buildPatchPlan(body || {}, inventory, vulnerability);
    const status = plan.summary?.alert_required ? "blocked_no_backup" : "awaiting_approval";

    const created = await patchStore.createJob(
      {
        status,
        requested_by: actor,
        target_ip: String(plan.summary?.target_ip || body?.target_ip || body?.ip || ""),
        target_name: String(plan.summary?.target_name || body?.target_name || body?.name || ""),
        target_type: String(plan.summary?.target_type || "unknown"),
        host_alias: String(plan.summary?.host_alias || body?.host_alias || ""),
        cve_id: String(plan.summary?.cve?.id || body?.cve_id || "").toUpperCase(),
        request_note: String(body?.request_note || body?.note || ""),
        clone_requested: body?.clone_vm === true,
        plan,
        execution: {
          mode: process.env.OSYRUS_PATCH_EXECUTION_MODE || "dry-run",
          state: "pending",
        },
      },
      actor,
    );

    sendJson(res, 201, {
      job: created,
      message: status === "blocked_no_backup"
        ? "Patch request created but blocked: no automated backup/rollback path detected"
        : "Patch request created and awaiting approval",
    });
    return true;
  }

  const byIdMatch = pathname.match(/^\/api\/patch\/jobs\/(\d+)$/);
  if (byIdMatch && method === "GET") {
    const id = Number(byIdMatch[1]);
    const job = await patchStore.getJob(id);
    if (!job) {
      sendJson(res, 404, { error: "Patch job not found" });
      return true;
    }
    sendJson(res, 200, { job });
    return true;
  }

  const approveMatch = pathname.match(/^\/api\/patch\/jobs\/(\d+)\/approve$/);
  if (approveMatch && method === "POST") {
    const auth = authorizePatchMutation(req, "approve");
    if (!auth.ok) {
      sendJson(res, auth.statusCode, { error: auth.message });
      return true;
    }

    const id = Number(approveMatch[1]);
    const body = await readJsonBody(req);
    const actor = extractActor(req, body, "approver");
    const job = await patchStore.getJob(id);
    if (!job) {
      sendJson(res, 404, { error: "Patch job not found" });
      return true;
    }

    const forceWithoutBackup = body?.force_without_backup === true;
    if (job.status === "blocked_no_backup" && !forceWithoutBackup) {
      sendJson(res, 409, {
        error: "Job is blocked due to missing rollback path. Re-submit approve with force_without_backup=true to continue.",
      });
      return true;
    }
    if (!["awaiting_approval", "blocked_no_backup"].includes(job.status)) {
      sendJson(res, 409, { error: `Cannot approve job in status ${job.status}` });
      return true;
    }

    const updated = await patchStore.updateJob(
      id,
      {
        status: "approved",
        approved_by: actor,
        force_without_backup: forceWithoutBackup || job.force_without_backup === true,
        last_error: "",
      },
      actor,
      "approved",
      {
        force_without_backup: forceWithoutBackup,
      },
    );
    sendJson(res, 200, { job: updated });
    return true;
  }

  const executeMatch = pathname.match(/^\/api\/patch\/jobs\/(\d+)\/execute$/);
  if (executeMatch && method === "POST") {
    const auth = authorizePatchMutation(req, "execute");
    if (!auth.ok) {
      sendJson(res, auth.statusCode, { error: auth.message });
      return true;
    }

    const id = Number(executeMatch[1]);
    const body = await readJsonBody(req);
    const actor = extractActor(req, body, "executor");
    const job = await patchStore.getJob(id);
    if (!job) {
      sendJson(res, 404, { error: "Patch job not found" });
      return true;
    }
    if (job.status !== "approved") {
      sendJson(res, 409, { error: `Cannot execute job in status ${job.status}` });
      return true;
    }

    const launch = await startPatchExecution({
      job,
      store: patchStore,
      rootDir,
      actor,
    });
    const running = await patchStore.getJob(id);
    sendJson(res, 202, {
      message: "Patch execution started",
      launch,
      job: running,
    });
    return true;
  }

  send(res, 404, "Not Found");
  return true;
}

async function getDbStatus() {
  if (!hasDatabase()) {
    return {
      configured: false,
      reachable: false,
      error: null,
    };
  }

  try {
    await query("SELECT 1");
    return {
      configured: true,
      reachable: true,
      error: null,
    };
  } catch (error) {
    return {
      configured: true,
      reachable: false,
      error: error.message,
    };
  }
}

async function maybeServeHealth(pathname, method, res) {
  if (pathname !== "/api/health") {
    return false;
  }

  const db = await getDbStatus();
  const statusCode = dbRequired && !db.reachable ? 503 : 200;
  const payload = {
    status: statusCode === 200 ? "ok" : "degraded",
    database: db,
    db_required: dbRequired,
    db_auto_import: autoImport,
    patch_execution_mode: process.env.OSYRUS_PATCH_EXECUTION_MODE || "dry-run",
    patch_tokens_configured: {
      request: Boolean(getPatchConfiguredToken("request")),
      approve: Boolean(getPatchConfiguredToken("approve")),
      execute: Boolean(getPatchConfiguredToken("execute")),
    },
    timestamp: new Date().toISOString(),
  };

  if (method === "HEAD") {
    sendHead(res, statusCode, contentTypes[".json"]);
    return true;
  }

  send(res, statusCode, `${JSON.stringify(payload, null, 2)}\n`, contentTypes[".json"]);
  return true;
}

async function maybeServeDataset(pathname, method, res) {
  const dataset = ROUTE_TO_DATASET.get(pathname);
  if (!dataset) {
    return false;
  }

  const resolved = await resolveDatasetPayload(dataset.name, {
    rootDir,
    autoImport,
    strictDatabase: dbRequired,
  });

  if (!resolved) {
    send(res, 404, "Not Found");
    return true;
  }

  const headers = {
    "X-Osyrus-Data-Source": resolved.source,
  };
  if (method === "HEAD") {
    sendHead(res, 200, contentTypes[".json"], headers);
    return true;
  }

  send(res, 200, `${JSON.stringify(resolved.payload, null, 2)}\n`, contentTypes[".json"], headers);
  return true;
}

function serveStatic(pathname, method, res) {
  const requested = pathname === "/" ? "/index.html" : pathname;
  const fullPath = path.resolve(rootDir, `.${requested}`);

  if (!fullPath.startsWith(rootDir)) {
    send(res, 403, "Forbidden");
    return;
  }

  fs.stat(fullPath, (err, stat) => {
    if (err || !stat.isFile()) {
      send(res, 404, "Not Found");
      return;
    }

    const ext = path.extname(fullPath).toLowerCase();
    const contentType = contentTypes[ext] || "application/octet-stream";

    if (method === "HEAD") {
      sendHead(res, 200, contentType);
      return;
    }

    const stream = fs.createReadStream(fullPath);
    res.writeHead(200, {
      "Content-Type": contentType,
      "Cache-Control": "no-store",
    });
    stream.pipe(res);
    stream.on("error", () => {
      if (!res.headersSent) {
        send(res, 500, "Internal Server Error");
      } else {
        res.end();
      }
    });
  });
}

async function handleRequest(req, res) {
  const method = req.method || "GET";
  const parsed = new URL(req.url || "/", "http://localhost");
  const pathname = decodeURIComponent(parsed.pathname);

  if (await maybeServePatchApi(req, parsed, pathname, method, res)) {
    return;
  }

  if (!["GET", "HEAD"].includes(method)) {
    send(res, 405, "Method Not Allowed");
    return;
  }

  if (await maybeServeHealth(pathname, method, res)) {
    return;
  }
  if (await maybeServeDataset(pathname, method, res)) {
    return;
  }
  serveStatic(pathname, method, res);
}

if (dbRequired && !hasDatabase()) {
  process.stderr.write("PORTAL_DB_REQUIRED=true but DATABASE_URL is not set.\n");
}

http
  .createServer((req, res) => {
    handleRequest(req, res).catch((error) => {
      send(res, 500, `Internal Server Error: ${error.message}`);
    });
  })
  .listen(port, () => {
    const dbMode = hasDatabase() ? "database-enabled" : "file-only";
    process.stdout.write(`Osyrus portal listening on http://0.0.0.0:${port} (${dbMode})\n`);
  });
