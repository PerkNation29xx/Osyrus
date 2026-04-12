"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");

const { hasDatabase, query } = require("./db");

const FILE_NAME = "patch_jobs.json";

function nowIso() {
  return new Date().toISOString();
}

function parseJsonField(value, fallback = {}) {
  if (value == null) {
    return fallback;
  }
  if (typeof value === "object") {
    return value;
  }
  try {
    return JSON.parse(value);
  } catch (_error) {
    return fallback;
  }
}

function normalizeDbJob(row) {
  return {
    id: Number(row.id),
    created_at: row.created_at instanceof Date ? row.created_at.toISOString() : row.created_at,
    updated_at: row.updated_at instanceof Date ? row.updated_at.toISOString() : row.updated_at,
    status: row.status,
    requested_by: row.requested_by,
    approved_by: row.approved_by || "",
    executed_by: row.executed_by || "",
    target_ip: row.target_ip || "",
    target_name: row.target_name || "",
    target_type: row.target_type || "",
    host_alias: row.host_alias || "",
    cve_id: row.cve_id || "",
    request_note: row.request_note || "",
    clone_requested: row.clone_requested === true,
    force_without_backup: row.force_without_backup === true,
    plan: parseJsonField(row.plan, {}),
    execution: parseJsonField(row.execution, {}),
    last_error: row.last_error || "",
    events: [],
  };
}

async function ensureFileStore(rootDir) {
  const filePath = path.join(rootDir, FILE_NAME);
  try {
    const raw = await fs.readFile(filePath, "utf8");
    const data = JSON.parse(raw);
    if (typeof data.next_id !== "number") {
      data.next_id = 1;
    }
    if (!Array.isArray(data.jobs)) {
      data.jobs = [];
    }
    if (!Array.isArray(data.events)) {
      data.events = [];
    }
    return { filePath, data };
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw error;
    }
    return {
      filePath,
      data: {
        next_id: 1,
        jobs: [],
        events: [],
      },
    };
  }
}

async function writeFileStore(filePath, data) {
  const tempPath = `${filePath}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(data, null, 2));
  await fs.rename(tempPath, filePath);
}

async function listFromDb(limit) {
  const jobsResult = await query(
    `
      SELECT *
      FROM patch_jobs
      ORDER BY updated_at DESC, id DESC
      LIMIT $1
    `,
    [limit],
  );

  const jobs = jobsResult.rows.map(normalizeDbJob);
  if (jobs.length === 0) {
    return {
      generated_at: nowIso(),
      total: 0,
      jobs: [],
    };
  }

  const ids = jobs.map((job) => job.id);
  const eventsResult = await query(
    `
      SELECT id, job_id, created_at, actor, event_type, details
      FROM patch_job_events
      WHERE job_id = ANY($1::bigint[])
      ORDER BY created_at DESC, id DESC
    `,
    [ids],
  );

  const byJobId = new Map();
  for (const row of eventsResult.rows) {
    const item = {
      id: Number(row.id),
      job_id: Number(row.job_id),
      created_at: row.created_at instanceof Date ? row.created_at.toISOString() : row.created_at,
      actor: row.actor || "",
      event_type: row.event_type || "",
      details: parseJsonField(row.details, {}),
    };
    const list = byJobId.get(item.job_id) || [];
    list.push(item);
    byJobId.set(item.job_id, list);
  }

  for (const job of jobs) {
    job.events = (byJobId.get(job.id) || []).slice(0, 12);
  }

  return {
    generated_at: nowIso(),
    total: jobs.length,
    jobs,
  };
}

async function getFromDb(id) {
  const result = await query("SELECT * FROM patch_jobs WHERE id = $1", [id]);
  if (result.rowCount === 0) {
    return null;
  }
  const job = normalizeDbJob(result.rows[0]);

  const eventsResult = await query(
    `
      SELECT id, job_id, created_at, actor, event_type, details
      FROM patch_job_events
      WHERE job_id = $1
      ORDER BY created_at DESC, id DESC
      LIMIT 30
    `,
    [id],
  );
  job.events = eventsResult.rows.map((row) => ({
    id: Number(row.id),
    job_id: Number(row.job_id),
    created_at: row.created_at instanceof Date ? row.created_at.toISOString() : row.created_at,
    actor: row.actor || "",
    event_type: row.event_type || "",
    details: parseJsonField(row.details, {}),
  }));
  return job;
}

function buildDbUpdateQuery(id, patch) {
  const columns = [];
  const values = [];
  let index = 1;

  const allowText = [
    "status",
    "requested_by",
    "approved_by",
    "executed_by",
    "target_ip",
    "target_name",
    "target_type",
    "host_alias",
    "cve_id",
    "request_note",
    "last_error",
  ];
  const allowBool = [
    "clone_requested",
    "force_without_backup",
  ];

  for (const key of allowText) {
    if (!(key in patch)) {
      continue;
    }
    columns.push(`${key} = $${index}`);
    values.push(String(patch[key] ?? ""));
    index += 1;
  }
  for (const key of allowBool) {
    if (!(key in patch)) {
      continue;
    }
    columns.push(`${key} = $${index}`);
    values.push(patch[key] === true);
    index += 1;
  }
  if ("plan" in patch) {
    columns.push(`plan = $${index}::jsonb`);
    values.push(JSON.stringify(patch.plan || {}));
    index += 1;
  }
  if ("execution" in patch) {
    columns.push(`execution = $${index}::jsonb`);
    values.push(JSON.stringify(patch.execution || {}));
    index += 1;
  }

  columns.push("updated_at = NOW()");
  values.push(id);

  const sql = `
    UPDATE patch_jobs
    SET ${columns.join(", ")}
    WHERE id = $${index}
    RETURNING *
  `;
  return { sql, values };
}

function createPatchStore({ rootDir }) {
  async function listJobs(limit = 100) {
    if (hasDatabase()) {
      try {
        return await listFromDb(limit);
      } catch (error) {
        process.stderr.write(`patch db list failed, using file fallback: ${error.message}\n`);
      }
    }

    const { data } = await ensureFileStore(rootDir);
    const jobs = [...data.jobs]
      .sort((a, b) => String(b.updated_at || "").localeCompare(String(a.updated_at || "")))
      .slice(0, limit)
      .map((job) => ({
        ...job,
        events: (data.events || [])
          .filter((event) => Number(event.job_id) === Number(job.id))
          .sort((a, b) => String(b.created_at || "").localeCompare(String(a.created_at || "")))
          .slice(0, 12),
      }));
    return {
      generated_at: nowIso(),
      total: jobs.length,
      jobs,
    };
  }

  async function getJob(id) {
    const numericId = Number(id);
    if (!Number.isFinite(numericId) || numericId <= 0) {
      return null;
    }

    if (hasDatabase()) {
      try {
        return await getFromDb(numericId);
      } catch (error) {
        process.stderr.write(`patch db get failed, using file fallback: ${error.message}\n`);
      }
    }

    const { data } = await ensureFileStore(rootDir);
    const job = data.jobs.find((item) => Number(item.id) === numericId);
    if (!job) {
      return null;
    }
    return {
      ...job,
      events: (data.events || [])
        .filter((event) => Number(event.job_id) === numericId)
        .sort((a, b) => String(b.created_at || "").localeCompare(String(a.created_at || ""))),
    };
  }

  async function addEvent(jobId, actor, eventType, details = {}) {
    const numericJobId = Number(jobId);
    const timestamp = nowIso();

    if (hasDatabase()) {
      try {
        await query(
          `
            INSERT INTO patch_job_events (job_id, actor, event_type, details)
            VALUES ($1, $2, $3, $4::jsonb)
          `,
          [numericJobId, actor || "system", eventType || "event", JSON.stringify(details || {})],
        );
        return;
      } catch (error) {
        process.stderr.write(`patch db event failed, using file fallback: ${error.message}\n`);
      }
    }

    const { filePath, data } = await ensureFileStore(rootDir);
    data.events.push({
      id: data.events.length + 1,
      job_id: numericJobId,
      actor: actor || "system",
      event_type: eventType || "event",
      details: details || {},
      created_at: timestamp,
    });
    await writeFileStore(filePath, data);
  }

  async function createJob(job, eventActor = "system") {
    const base = {
      created_at: nowIso(),
      updated_at: nowIso(),
      status: "awaiting_approval",
      requested_by: "unknown",
      approved_by: "",
      executed_by: "",
      target_ip: "",
      target_name: "",
      target_type: "",
      host_alias: "",
      cve_id: "",
      request_note: "",
      clone_requested: false,
      force_without_backup: false,
      plan: {},
      execution: {},
      last_error: "",
      ...job,
    };

    if (hasDatabase()) {
      try {
        const result = await query(
          `
            INSERT INTO patch_jobs (
              status,
              requested_by,
              approved_by,
              executed_by,
              target_ip,
              target_name,
              target_type,
              host_alias,
              cve_id,
              request_note,
              clone_requested,
              force_without_backup,
              plan,
              execution,
              last_error
            )
            VALUES (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
              $11, $12, $13::jsonb, $14::jsonb, $15
            )
            RETURNING *
          `,
          [
            base.status,
            base.requested_by,
            base.approved_by,
            base.executed_by,
            base.target_ip,
            base.target_name,
            base.target_type,
            base.host_alias,
            base.cve_id,
            base.request_note,
            base.clone_requested === true,
            base.force_without_backup === true,
            JSON.stringify(base.plan || {}),
            JSON.stringify(base.execution || {}),
            base.last_error || "",
          ],
        );
        const created = normalizeDbJob(result.rows[0]);
        await addEvent(created.id, eventActor, "requested", {
          status: created.status,
          target_ip: created.target_ip,
          target_name: created.target_name,
        });
        return created;
      } catch (error) {
        process.stderr.write(`patch db create failed, using file fallback: ${error.message}\n`);
      }
    }

    const { filePath, data } = await ensureFileStore(rootDir);
    const created = {
      ...base,
      id: data.next_id,
      events: [],
    };
    data.next_id += 1;
    data.jobs.push(created);
    data.events.push({
      id: data.events.length + 1,
      job_id: created.id,
      actor: eventActor,
      event_type: "requested",
      details: {
        status: created.status,
        target_ip: created.target_ip,
        target_name: created.target_name,
      },
      created_at: nowIso(),
    });
    await writeFileStore(filePath, data);
    return created;
  }

  async function updateJob(id, patch, eventActor = "", eventType = "", eventDetails = {}) {
    const numericId = Number(id);
    if (!Number.isFinite(numericId) || numericId <= 0) {
      return null;
    }

    if (hasDatabase()) {
      try {
        const { sql, values } = buildDbUpdateQuery(numericId, patch || {});
        const result = await query(sql, values);
        if (result.rowCount === 0) {
          return null;
        }
        const updated = normalizeDbJob(result.rows[0]);
        if (eventType) {
          await addEvent(updated.id, eventActor || "system", eventType, eventDetails || {});
        }
        return updated;
      } catch (error) {
        process.stderr.write(`patch db update failed, using file fallback: ${error.message}\n`);
      }
    }

    const { filePath, data } = await ensureFileStore(rootDir);
    const index = data.jobs.findIndex((item) => Number(item.id) === numericId);
    if (index < 0) {
      return null;
    }
    const updated = {
      ...data.jobs[index],
      ...patch,
      updated_at: nowIso(),
    };
    data.jobs[index] = updated;

    if (eventType) {
      data.events.push({
        id: data.events.length + 1,
        job_id: numericId,
        actor: eventActor || "system",
        event_type: eventType,
        details: eventDetails || {},
        created_at: nowIso(),
      });
    }

    await writeFileStore(filePath, data);
    return updated;
  }

  return {
    listJobs,
    getJob,
    createJob,
    updateJob,
    addEvent,
  };
}

module.exports = {
  createPatchStore,
};
