# Evidence map

Run the stack from the repository root first: copy `.env.example` to `.env`, then `docker compose up --build`. Paste command output into the report section named below. Generated runs land in `docs/evidence/runs/`, which is git-ignored.

| Rubric | Where it is produced | What to put in the report |
|---|---|---|
| C1 Clean start | `README.md` | `docker compose ps` after a fresh `up --build`. Every service `healthy` or running, and only ports 3001 and 3002 published. |
| C2 Network isolation | `docker-compose.yml` | `docker ps` showing `0.0.0.0:3001` and `:3002` only. A connection to `localhost:3306` and `:27017` should fail. |
| C3 Image optimization | `scripts/measure_images.ps1`, `docs/evidence/C3-image-optimization.md` | The size and build-time table. |
| C4 Vulnerability scan | `.github/workflows/ci.yml` | Download the `trivy-*` artifacts. Note each HIGH and CRITICAL finding and whether it was fixed or accepted. |
| C5 Failure tests | `scripts/test_failure.ps1`, `docs/evidence/C5-failure-tests.md` | The two summary tables the script prints. |
| C6 Persistence | `scripts/test_persistence.ps1`, `docs/evidence/C6-persistence.md` | The before/after count table. |
| C7 Load test | `tests/load/k6_test.js`, `docs/evidence/C7-load-test.md` | Baseline k6 summary, `docker stats`, then the same table after the two optimizations. |
| C8 Green pipeline | `.github/workflows/ci.yml` | Link or screenshot of a run whose test, scan, tag, and push jobs are green. Images are `ghcr.io/<owner>/<repo>/<service>:<git-sha>` and `:latest`. |
| C9 README | `README.md` | A teammate follows only that file. |

MySQL and MongoDB are the upstream `mysql:8.4` and `mongo:7` images. CI builds and scans only `auth`, `enterdata`, `analytics`, and `showresults`.

On Linux or Git Bash, the same steps are `scripts/test_failure.sh`, `scripts/test_persistence.sh`, and `scripts/measure_images.sh`.
