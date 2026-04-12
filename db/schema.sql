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

CREATE TABLE IF NOT EXISTS patch_jobs (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status TEXT NOT NULL DEFAULT 'awaiting_approval',
  requested_by TEXT NOT NULL,
  approved_by TEXT NOT NULL DEFAULT '',
  executed_by TEXT NOT NULL DEFAULT '',
  target_ip TEXT NOT NULL,
  target_name TEXT NOT NULL DEFAULT '',
  target_type TEXT NOT NULL DEFAULT 'unknown',
  host_alias TEXT NOT NULL DEFAULT '',
  cve_id TEXT NOT NULL DEFAULT '',
  request_note TEXT NOT NULL DEFAULT '',
  clone_requested BOOLEAN NOT NULL DEFAULT FALSE,
  force_without_backup BOOLEAN NOT NULL DEFAULT FALSE,
  plan JSONB NOT NULL DEFAULT '{}'::jsonb,
  execution JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_error TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS ix_patch_jobs_updated
  ON patch_jobs (updated_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS ix_patch_jobs_status
  ON patch_jobs (status);

CREATE TABLE IF NOT EXISTS patch_job_events (
  id BIGSERIAL PRIMARY KEY,
  job_id BIGINT NOT NULL REFERENCES patch_jobs(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actor TEXT NOT NULL DEFAULT 'system',
  event_type TEXT NOT NULL,
  details JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS ix_patch_job_events_job
  ON patch_job_events (job_id, created_at DESC, id DESC);
