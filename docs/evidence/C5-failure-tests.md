# C5 — Failure tests

Start the full stack, then:

```powershell
pwsh scripts/test_failure.ps1
```

```bash
bash scripts/test_failure.sh
```

The script stops MySQL, watches Enter Data and the analytics logs, starts MySQL, and records how long health takes to return. It then stops Auth, sends the same requests again, and checks that Enter Data and Show Results are still running. It always starts `mysql` and `auth` again before it exits. A copy of the terminal markdown is written under `docs/evidence/runs/`.

## What a pass looks like

**MySQL stopped.** `POST /data` on port 3001 with a valid cookie returns **503** and the page says the database is unavailable. Enter Data's `/health` stays OK because that route does not open MySQL. The container stays `running` and its restart count does not climb. Analytics logs `job_error` and keeps looping; its heartbeat can still look healthy. That log line is the analytics evidence, not the health status. After `docker compose start mysql`, MySQL becomes `healthy`, Auth becomes `healthy` again because `/health` opens MySQL, and a later analytics line says `docs_written`. The next insert returns **200**.

**Auth stopped.** `GET /data` and `GET /results` with no cookie return **401**. Those routes do not call Auth when there is no cookie. `POST /login`, and the same pages with a cookie from before the outage, return **503** and the page says Auth is unavailable. That is a clean error from the web apps, not a crash: `enterdata` and `showresults` stay `running` and the restart counts stay the same. After `docker compose start auth`, login returns **303** again.

Copy the script's two summary tables below this line.

### Test 1 summary

Measured 22 Oct 2026.

| Check | Observation |
|---|---|
| Insert before stop | HTTP 200 saved |
| Insert while MySQL stopped | HTTP 503 database unavailable |
| Insert after recovery | HTTP 200 saved |
| enterdata process | running, healthy, restarts 0 |
| analytics job_error | seen after 1s, repeated 5s later |
| MySQL healthy again | 6 s |
| Auth healthy again | 1 s after MySQL was healthy |
| analytics docs_written | seen |

### Test 2 summary

| Request | Auth up | Auth stopped | Auth restored |
|---|---|---|---|
| POST /login on :3001 | 303 | 503 auth unavailable | 303 |
| GET /data with cookie | 200 | 503 auth unavailable | 200 |
| GET /data with no cookie | 401 | 401 | 401 |
| POST /login on :3002 | 303 | 503 auth unavailable | 303 |
| GET /results with cookie | 200 | 503 auth unavailable | 200 |
| GET /results with no cookie | 401 | 401 | 401 |

| Process | Restarts before | Status during outage | Restarts during outage |
|---|---|---|---|
| enterdata | 0 | running / healthy | 0 |
| showresults | 0 | running / healthy | 0 |

Auth was healthy 6s after `docker compose start auth`.
