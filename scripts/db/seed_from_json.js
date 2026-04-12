"use strict";

const path = require("node:path");

const { DATASET_REGISTRY } = require("../../lib/datasets");
const { hasDatabase, closePool } = require("../../lib/db");
const { importSnapshotFromFile } = require("../../lib/snapshot_store");

function parseArgs(argv) {
  const flags = {
    quiet: false,
    onlyIfChanged: false,
    datasets: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--quiet") {
      flags.quiet = true;
      continue;
    }
    if (arg === "--only-if-changed") {
      flags.onlyIfChanged = true;
      continue;
    }
    if (arg === "--dataset") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--dataset requires a dataset name");
      }
      flags.datasets.push(value);
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return flags;
}

function logLine(quiet, message) {
  if (!quiet) {
    process.stdout.write(`${message}\n`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!hasDatabase()) {
    throw new Error("DATABASE_URL is not set. Cannot seed DB.");
  }

  const rootDir = path.join(__dirname, "..", "..");
  const allowed = new Set(DATASET_REGISTRY.map((item) => item.name));
  const targets = args.datasets.length > 0
    ? args.datasets
    : DATASET_REGISTRY.map((item) => item.name);

  let importedCount = 0;
  let skippedCount = 0;
  let missingCount = 0;

  for (const datasetName of targets) {
    if (!allowed.has(datasetName)) {
      throw new Error(`Unknown dataset: ${datasetName}`);
    }

    try {
      const result = await importSnapshotFromFile(datasetName, {
        rootDir,
        source: "seed-script",
        onlyIfChanged: args.onlyIfChanged,
      });
      if (result.imported) {
        importedCount += 1;
        logLine(args.quiet, `Imported ${datasetName} from ${result.filePath}`);
      } else {
        skippedCount += 1;
        logLine(args.quiet, `Skipped ${datasetName} (${result.reason})`);
      }
    } catch (error) {
      if (error?.code === "ENOENT") {
        missingCount += 1;
        logLine(args.quiet, `Missing ${datasetName} file; skipping`);
        continue;
      }
      throw error;
    }
  }

  process.stdout.write(
    `DB seed complete: imported=${importedCount} skipped=${skippedCount} missing=${missingCount}\n`,
  );
}

main()
  .catch((error) => {
    process.stderr.write(`db:seed failed: ${error.message}\n`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closePool();
  });
