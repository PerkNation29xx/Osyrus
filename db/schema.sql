CREATE TABLE IF NOT EXISTS portal_snapshots (
  id BIGSERIAL PRIMARY KEY,
  dataset_name TEXT NOT NULL,
  generated_at TIMESTAMPTZ NULL,
  source TEXT NOT NULL DEFAULT 'unknown',
  schema_version INTEGER NOT NULL DEFAULT 1,
  payload JSONB NOT NULL,
  payload_sha256 TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_portal_snapshots_dataset_hash
  ON portal_snapshots (dataset_name, payload_sha256);

CREATE INDEX IF NOT EXISTS ix_portal_snapshots_latest
  ON portal_snapshots (dataset_name, COALESCE(generated_at, created_at) DESC, created_at DESC, id DESC);
