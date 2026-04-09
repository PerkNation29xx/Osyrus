const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");

const rootDir = __dirname;
const port = Number(process.env.PORT || 8090);

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
};

function send(res, statusCode, body, contentType = "text/plain; charset=utf-8") {
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
  });
  res.end(body);
}

http
  .createServer((req, res) => {
    const method = req.method || "GET";
    if (!["GET", "HEAD"].includes(method)) {
      return send(res, 405, "Method Not Allowed");
    }

    const requestPath = (req.url || "/").split("?")[0];
    const decodedPath = decodeURIComponent(requestPath);
    const requested = decodedPath === "/" ? "/index.html" : decodedPath;
    const fullPath = path.resolve(rootDir, `.${requested}`);

    if (!fullPath.startsWith(rootDir)) {
      return send(res, 403, "Forbidden");
    }

    fs.stat(fullPath, (err, stat) => {
      if (err || !stat.isFile()) {
        return send(res, 404, "Not Found");
      }

      const ext = path.extname(fullPath).toLowerCase();
      const contentType = contentTypes[ext] || "application/octet-stream";

      if (method === "HEAD") {
        res.writeHead(200, {
          "Content-Type": contentType,
          "Cache-Control": "no-store",
        });
        return res.end();
      }

      const stream = fs.createReadStream(fullPath);
      res.writeHead(200, {
        "Content-Type": contentType,
        "Cache-Control": "no-store",
      });
      stream.pipe(res);
      stream.on("error", () => send(res, 500, "Internal Server Error"));
    });
  })
  .listen(port, () => {
    process.stdout.write(`Osyrus portal listening on http://0.0.0.0:${port}\n`);
  });
