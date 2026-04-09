# Render Deployment Notes

This portal directory is now Render-ready.

## What Is Included
- `render.yaml`: Render Blueprint service definition
- `package.json`: Node start command
- `server.js`: static file server for `index.html` + JSON artifacts

## Deploy Steps
1. Push this `portal` folder to a Git repository.
2. In Render, choose **New +** -> **Blueprint**.
3. Select the repository and branch.
4. Confirm `render.yaml` is detected.
5. Deploy when ready.

## Public URL
After deployment, Render provides a public URL.  
That URL serves:
- `/` -> portal dashboard
- `/vulnerability_report.json`
- `/VULN_UPGRADE_PATH_PLAN.md`
- `/inventory.json`
