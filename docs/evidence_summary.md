# CIT3495 evidence summary

Captured on this machine on 22 Oct 2026, with the Compose project `cit3495_project1` already healthy. Raw transcripts are in `docs/evidence/runs/`.

## Persistence

Command: `powershell -ExecutionPolicy Bypass -File .\scripts\test_persistence.ps1`

The script inserted four `persist-check` rows, waited until MongoDB's `stats` count matched MySQL (22s, count 8), then ran `docker compose rm -sf mysql mongo` and `docker compose up -d mysql mongo`. No `-v` was used. An earlier attempt had inserted four rows and stopped before removing containers, because `db.stats` in `mongosh` is the `stats()` command rather than the collection. The script now uses `db.getCollection('stats')`. The successful run is the one below, so the category already held eight rows.

```text
Container cit3495_project1-mysql-1 Removed
Container cit3495_project1-mongo-1 Removed
Container cit3495_project1-mysql-1 Started
Container cit3495_project1-mongo-1 Started
Both databases reported healthy 7s after recreate.
Result: no data loss.
```

| Count | Before rm | After recreate | Match |
|---|---:|---:|---|
| MySQL measurements | 8 | 8 | yes |
| MySQL users | 1 | 1 | yes |
| MySQL rows in persist-check | 8 | 8 | yes |
| Mongo stats count for persist-check | 8 | 8 | yes |
| Mongo stats documents | 1 | 1 | yes |

Recreate plus health took 8s. Full log: `docs/evidence/runs/persistence-20261022-225209.md`.

## Failure and recovery

Command: `powershell -ExecutionPolicy Bypass -File .\scripts\test_failure.ps1`

### MySQL

`docker compose stop mysql`. Enter Data stayed running (restart count 0). A logged-in insert returned HTTP 503 and the page said the database was unavailable. Analytics logged `job_error` 1s after the stop, then again 5s later, which is the job's starting backoff. Its health check stayed `healthy` because the heartbeat file was still being touched. The failure evidence is the log, not that health status.

```text
2026-10-23T05:52:22.161185524Z {"svc": "analytics", "event": "job_error", "error": "OperationalError", "msg": "(2003, \"Can't connect to MySQL server on 'mysql' ([Errno 111] Connection refused)\")"}
2026-10-23T05:52:27.163541617Z {"svc": "analytics", "event": "job_error", "error": "OperationalError", "msg": "(2003, \"Can't connect to MySQL server on 'mysql' ([Errno -3] Temporary failure in name resolution)\")"}
2026-10-23T05:52:37.186999535Z {"svc": "analytics", "event": "docs_written", "count": 2}
```

`docker compose start mysql`. MySQL was healthy in 6s. Auth, whose `/health` opens MySQL, was healthy 1s after that. The next insert returned HTTP 200. Wall clock from the start command through that insert was 11s.

| Check | Observation |
|---|---|
| Insert before stop | HTTP 200 saved |
| Insert while MySQL stopped | HTTP 503 database unavailable |
| Insert after recovery | HTTP 200 saved |
| enterdata process | running, health healthy, restarts 0 |
| analytics job_error | seen after 1s, then again 5s later |
| MySQL healthy again | 6 s |
| Auth healthy again | 1 s after MySQL was healthy |
| analytics docs_written | seen |

### Auth

`docker compose stop auth`, then `docker compose start auth`. A request with no cookie does not call Auth, so those stayed HTTP 401. Login and the cookie-protected pages call Auth. While the container was stopped they returned HTTP 503 and the page said Auth was unavailable. Enter Data and Show Results stayed `running` and their restart counts stayed 0. Auth was healthy 6s after start, and login returned HTTP 303 again.

| Request | Auth up | Auth stopped | Auth restored |
|---|---|---|---|
| POST /login on :3001 | 303 | 503 auth unavailable | 303 |
| GET /data with cookie | 200 enter form | 503 auth unavailable | 200 enter form |
| GET /data with no cookie | 401 please log in | 401 please log in | 401 |
| POST /login on :3002 | 303 | 503 auth unavailable | 303 |
| GET /results with cookie | 200 results page | 503 auth unavailable | 200 results page |
| GET /results with no cookie | 401 please log in | 401 please log in | 401 |

| Process | Restarts before | Status during outage | Restarts during outage |
|---|---|---|---|
| enterdata | 0 | running / healthy | 0 |
| showresults | 0 | running / healthy | 0 |

Full log: `docs/evidence/runs/failure-20261022-225304.md`.

## Image size and build time

Command: `powershell -ExecutionPolicy Bypass -File .\scripts\measure_images.ps1`

That script builds with `--no-cache` and records `docker image inspect` size. `docker images` prints a different SIZE column for the same tags. Both are listed. Build time is wall clock for that build, including any base-image pull. The optimized bases (`python:3.12-slim`, `node:22-alpine`) were already on the machine because Compose uses them, so their build times are not a pure CPU comparison with the fat baselines.

| Image | Dockerfile | `docker images` SIZE | inspect (MB) | Build (s) |
|---|---|---:|---:|---:|
| analytics baseline | `analytics/Dockerfile.baseline` | 1.65GB | 1577.2 | 99.0 |
| analytics optimized | `analytics/Dockerfile` | 228MB | 217.7 | 23.0 |
| showresults baseline | `showresults/Dockerfile.baseline` | 1.65GB | 1573.0 | 81.5 |
| showresults optimized | `showresults/Dockerfile` | 255MB | 243.4 | 8.3 |

From the inspect sizes, the analytics image is 1359.5 MB smaller (86%) and the Show Results image is 1329.6 MB smaller (85%). Compose runs the optimized Dockerfiles. The `cit3495-*:baseline` and `:optimized` tags are measurement tags only.

## Load test

Both runs used `k6 run -e VUS=5 -e DURATION=30s tests/load/k6_test.js` against the running stack (5 virtual users, 30 seconds). Each iteration logs in to both sites, inserts one row, and reads `/results`. CPU and memory are the peaks from `scripts/sample_stats.ps1` over a 45s window that covered the run. Docker reports CPU as a fraction of one core, so 100% is one full core.

The second run is after three changes that sit on the login and insert path:

- Auth keeps one MySQL connection per Gunicorn worker instead of opening one per request.
- Auth runs 4 Gunicorn workers, with the Compose limit raised from 0.50 CPU / 256 MB to 1.00 CPU / 384 MB.
- Enter Data's pool went from 10 connections to 30.

`INDEX idx_category` was already created by `mysql/init.sh`. The analytics job reads every measurement, and this load test only inserts, so that index was not a new change and is not what moved these numbers.

| Metric | Baseline | After the three changes |
|---|---:|---:|
| Requests/sec | 3.81 | 7.39 |
| HTTP requests in the run | 121 | 237 |
| Iterations | 30 | 59 |
| Error rate | 0.82% (1/121) | 0% (0/237) |
| p95 latency | 2.66 s | 1.38 s |
| Login checks passed | enterdata 100%; showresults 29/30 | 100% on both |
| Insert checks passed | 100% | 100% |
| Results checks passed | 100% | 100% |
| auth CPU peak | 50.88% | 99.52% |
| auth memory peak | 81.96 MiB / 256 MiB | 125.5 MiB / 384 MiB |
| enterdata CPU peak | 21.73% | 43.70% |
| enterdata memory peak | 81.84 MiB | 33.94 MiB |
| mysql CPU peak | 2.10% | 4.64% |
| mysql memory peak | 437.1 MiB / 512 MiB | 438.2 MiB / 512 MiB |

The baseline's single failure was one Show Results login that did not return 303. After the Auth changes, every check passed. Throughput was about 1.9 times the baseline and p95 latency was about half. Auth's CPU peak moved from half a core to one core, which is the new limit, so bcrypt was using the extra CPU that was given to it. Enter Data's memory peak is lower on the second run; that container had just been recreated, so the two memory numbers are not a steady-state comparison.

Transcripts: `docs/evidence/runs/k6-baseline.txt`, `docs/evidence/runs/k6-optimized.txt`, `docs/evidence/runs/docker-stats-20261022-225721.csv`, `docs/evidence/runs/docker-stats-20261022-225927.csv`.
