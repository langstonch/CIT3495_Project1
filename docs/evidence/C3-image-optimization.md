# C3 — Image size and build time

Compose builds `analytics/Dockerfile` and `showresults/Dockerfile`. The `Dockerfile.baseline` files exist only so this comparison can be repeated. They are not what the stack runs.

What changed from baseline to the image Compose ships:

| Choice | Baseline | Optimized |
|---|---|---|
| analytics base | `python:3.12` (full image) | `python:3.12-slim`, multi-stage venv |
| analytics packages | `requirements.txt`, including pytest | `requirements.runtime.txt` (PyMySQL, cryptography, pymongo) |
| analytics user | root | uid 10001 |
| showresults base | `node:22` (Debian), single stage | `node:22-alpine`, deps stage then runtime stage |
| showresults user | root | `node` |
| layer order | source and install together | dependency install before application source |
| build context | `.dockerignore` drops tests, virtualenvs, `node_modules`, and `.env` for both builds | same ignore file |

The slim/alpine bases remove compilers and package indexes from the final layer. Leaving pytest out of the analytics venv avoids shipping the test runner. Copying the lockfile and requirements before the source means a code-only change does not reinstall dependencies. `.dockerignore` keeps test files and local environments out of the context, so they cannot land in a `COPY .` layer.

## How to measure

From the repository root, with Docker running. The default build uses `--no-cache` and pulls the base images, so the first run takes several minutes.

```powershell
pwsh scripts/measure_images.ps1
```

```bash
bash scripts/measure_images.sh
```

Paste the printed table here. Do not invent the numbers.

| Image | Dockerfile | Size (MB) | Build (s) |
|---|---|---:|---:|
| analytics baseline | `analytics/Dockerfile.baseline` |  |  |
| analytics optimized | `analytics/Dockerfile` |  |  |
| showresults baseline | `showresults/Dockerfile.baseline` |  |  |
| showresults optimized | `showresults/Dockerfile` |  |  |

The tags `cit3495-analytics:*` and `cit3495-showresults:*` are measurement tags. Removing them does not affect `docker compose`.
