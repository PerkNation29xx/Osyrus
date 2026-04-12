# Render Deployment Notes

This portal directory is now Render-ready.

## What Is Included
- `render.yaml`: Render Blueprint service definition
- `package.json`: Node start command
- `server.js`: web server for `index.html` + DB-backed JSON data routes
- `db/schema.sql`: snapshot schema
- `scripts/db/init_db.js`, `scripts/db/seed_from_json.js`: DB setup + ingest tools

## Deploy Steps
1. Push this `portal` folder to a Git repository.
2. In Render, choose **New +** -> **Blueprint**.
3. Select the repository and branch.
4. Confirm `render.yaml` is detected.
5. Add environment variables in Render:
- `DATABASE_URL` (Supabase or Postgres connection string)
- `DATABASE_SSL=require` (required for Supabase)
- Optional: `PORTAL_DB_REQUIRED=true`, `PORTAL_DB_AUTO_IMPORT=true`
6. Deploy when ready.

## Public URL
After deployment, Render provides a public URL.  
That URL serves:
- `/` -> portal dashboard
- `/vulnerability_report.json`
- `/VULN_UPGRADE_PATH_PLAN.md`
- `/inventory.json`
- `/api/health`
