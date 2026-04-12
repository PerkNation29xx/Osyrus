"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");

const { NAME_TO_DATASET } = require("./datasets");
const { hasDatabase, query } = require("./db");

const fileMtimeMsByDataset = new Map();

function sha256(text) {
  return crypto.createHash("sha256").update(text).digest("hex");
}

function parseGeneratedAt(payload) {
  const candidates = [
    payload?.generated_at,
    payload?.generatedAt,
    payload?.timestamp,
  ];
  for (const value of candidates) {
    if (!value || typeof value !== "string") {
      continue;
    }
    const timestamp = Date.parse(value);
    if (!Number.isNaN(timestamp)) {
      return new Date(timestamp).toISOString();
    }
  }
  return null;
}

async function upsertSnapshot({ datasetName, payload, source = "json-file", schemaVersion = 1 }) {
  const payloadText = JSON.stringify(payload);
  const payloadSha256 = sha256(payloadText);
  const generatedAt = parseGeneratedAt(payload);

  const result = await query(
    `
      INSERT INTO portal_snapshots (
        dataset_name,
        generated_at,
        source,
        schema_version,
        payload,
        payload_sha256
      )
      VALUES ($1, $2::timestamptz, $3, $4, $5::jsonb, $6)
      ON CONFLICT (dataset_name, payload_sha256)
      DO NOTHING
      RETURNING id
    `,
    [datasetName, generatedAt, source, schemaVersion, payloadText, payloadSha256],
  );

  return {
    inserted: result.rowCount > 0,
    generatedAt,
    payloadSha256,
  };
}

async function getLatestSnapshot(datasetName) {
  const result = await query(
    `
      SELECT
        id,
        dataset_name,
        generated_at,
        source,
        schema_version,
        payload,
        created_at
      FROM portal_snapshots
      WHERE dataset_name = $1
      ORDER BY COALESCE(generated_at, created_at) DESC, created_at DESC, id DESC
      LIMIT 1
    `,
    [datasetName],
  );
  return result.rows[0] || null;
}

async function readJsonFromFile(filePath) {
  const raw = await fs.readFile(filePath, "utf8");
  return JSON.parse(raw);
}

async function importSnapshotFromFile(datasetName, options = {}) {
  const dataset = NAME_TO_DATASET.get(datasetName);
  if (!dataset) {
    throw new Error(`Unknown dataset: ${datasetName}`);
  }

  const rootDir = options.rootDir || process.cwd();
  const filePath = path.join(rootDir, dataset.file);
  const stats = await fs.stat(filePath);

  if (options.onlyIfChanged === true) {
    const previousMtime = fileMtimeMsByDataset.get(datasetName);
    if (previousMtime === stats.mtimeMs) {
      return { imported: false, reason: "unchanged", datasetName, filePath };
    }
  }

  const payload = await readJsonFromFile(filePath);
  if (hasDatabase()) {
    await upsertSnapshot({
      datasetName,
      payload,
      source: options.source || "file-import",
      schemaVersion: Number(options.schemaVersion || 1),
    });
  }
  fileMtimeMsByDataset.set(datasetName, stats.mtimeMs);
  return { imported: true, datasetName, filePath, payload };
}

async function resolveDatasetPayload(datasetName, options = {}) {
  const dataset = NAME_TO_DATASET.get(datasetName);
  if (!dataset) {
    return null;
  }

  const rootDir = options.rootDir || process.cwd();
  const autoImport = options.autoImport === true;
  const strictDatabase = options.strictDatabase === true;

  if (hasDatabase()) {
    if (autoImport) {
      try {
        await importSnapshotFromFile(datasetName, {
          rootDir,
          source: "auto-import",
          onlyIfChanged: true,
        });
      } catch (error) {
        if (error?.code !== "ENOENT") {
          process.stderr.write(`auto-import failed for ${datasetName}: ${error.message}\n`);
        }
      }
    }

    try {
      const row = await getLatestSnapshot(datasetName);
      if (row?.payload) {
        return {
          payload: row.payload,
          source: "database",
          metadata: {
            generated_at: row.generated_at,
            created_at: row.created_at,
            schema_version: row.schema_version,
            source: row.source,
          },
        };
      }
    } catch (error) {
      if (strictDatabase) {
        throw error;
      }
      process.stderr.write(`db read failed for ${datasetName}, falling back to file: ${error.message}\n`);
    }
  }

  try {
    const payload = await readJsonFromFile(path.join(rootDir, dataset.file));
    return {
      payload,
      source: "file",
      metadata: null,
    };
  } catch (error) {
    if (error?.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

module.exports = {
  upsertSnapshot,
  getLatestSnapshot,
  importSnapshotFromFile,
  resolveDatasetPayload,
};
