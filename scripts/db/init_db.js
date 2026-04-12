"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");

const { hasDatabase, query, closePool } = require("../../lib/db");

async function main() {
  if (!hasDatabase()) {
    throw new Error("DATABASE_URL is not set. Cannot initialize DB schema.");
  }

  const schemaPath = path.join(__dirname, "..", "..", "db", "schema.sql");
  const sql = await fs.readFile(schemaPath, "utf8");
  await query(sql);
  process.stdout.write("DB schema initialized successfully.\n");
}

main()
  .catch((error) => {
    process.stderr.write(`db:init failed: ${error.message}\n`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closePool();
  });
