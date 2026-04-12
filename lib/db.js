"use strict";

const { Pool } = require("pg");

let pool = null;

function envTruthy(value) {
  return ["1", "true", "yes", "on", "require", "required"].includes(String(value || "").toLowerCase());
}

function envFalsy(value) {
  return ["0", "false", "no", "off", "disable", "disabled"].includes(String(value || "").toLowerCase());
}

function isSupabaseUrl(url) {
  return /supabase\.(co|com)|pooler\.supabase/i.test(url || "");
}

function shouldUseSsl(databaseUrl) {
  const sslMode = process.env.DATABASE_SSL;
  if (envTruthy(sslMode)) {
    return true;
  }
  if (envFalsy(sslMode)) {
    return false;
  }
  return isSupabaseUrl(databaseUrl);
}

function hasDatabase() {
  return Boolean(process.env.DATABASE_URL);
}

function getPool() {
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    return null;
  }
  if (!pool) {
    const useSsl = shouldUseSsl(databaseUrl);
    pool = new Pool({
      connectionString: databaseUrl,
      ssl: useSsl ? { rejectUnauthorized: false } : false,
      max: Number(process.env.DATABASE_POOL_MAX || 10),
      idleTimeoutMillis: Number(process.env.DATABASE_IDLE_TIMEOUT_MS || 30000),
      connectionTimeoutMillis: Number(process.env.DATABASE_CONNECT_TIMEOUT_MS || 10000),
    });
  }
  return pool;
}

async function query(text, params) {
  const db = getPool();
  if (!db) {
    throw new Error("DATABASE_URL is not set");
  }
  return db.query(text, params);
}

async function closePool() {
  if (pool) {
    await pool.end();
    pool = null;
  }
}

module.exports = {
  hasDatabase,
  getPool,
  query,
  closePool,
};
