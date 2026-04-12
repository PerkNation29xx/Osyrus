const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");

const { ROUTE_TO_DATASET } = require("./lib/datasets");
const { hasDatabase, query } = require("./lib/db");
const { resolveDatasetPayload } = require("./lib/snapshot_store");

const rootDir = __dirname;
const port = Number(process.env.PORT || 8090);
const dbRequired = ["1", "true", "yes", "on"].includes(String(process.env.PORTAL_DB_REQUIRED || "").toLowerCase());
const autoImportSetting = process.env.PORTAL_DB_AUTO_IMPORT;
const autoImport = autoImportSetting == null
  ? true
  : ["1", "true", "yes", "on"].includes(String(autoImportSetting).toLowerCase());

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
  if (!["GET", "HEAD"].includes(method)) {
    send(res, 405, "Method Not Allowed");
    return;
  }

  const parsed = new URL(req.url || "/", "http://localhost");
  const pathname = decodeURIComponent(parsed.pathname);

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
