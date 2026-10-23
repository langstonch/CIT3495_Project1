# C7 — Load test and two optimizations

The script logs in to both sites, inserts one measurement, and reads `/results`, once per iteration. Auth is not published, so the load enters through ports 3001 and 3002. Each login pays a bcrypt compare, and every insert calls `GET /validate` before it touches MySQL.

```powershell
k6 run -e VUS=5 -e DURATION=30s -e ADMIN_USER=admin -e ADMIN_PASSWORD=change_this_password tests/load/k6_test.js
```

Use the real `ADMIN_PASSWORD` from `.env`. In another terminal, during the same window:

```powershell
pwsh scripts/sample_stats.ps1 -Seconds 40
```

Record the k6 summary (`http_reqs`, `http_req_failed`, `http_req_duration` p95, and the grouped checks) and the peak CPU and memory from the stats CSV. Run that once on the current code. Apply both changes below, rebuild with `docker compose up -d --build auth enterdata`, run the same k6 command, and fill the second column. Keep VUs and duration identical.

`measurements.category` already has `INDEX idx_category` in `mysql/init.sh`. The analytics job reads every row, and Enter Data only inserts, so that index does not change this load test. It is not one of the two improvements.

## 1. Reuse the Auth MySQL connection

`auth/app.py` calls `pymysql.connect` on every login, validate, and health check, and `with db() as c` closes that connection. Under k6 that is a new TCP handshake per request, on top of bcrypt. Gunicorn's sync workers handle one request at a time, so one connection per process is enough. Replace `db`, `get_hash`, and the database block inside `seed_admin` with:

```python
_conn = None

def db():
    global _conn
    try:
        if _conn is None or not _conn.open:
            raise pymysql.MySQLError("closed")
        _conn.ping(reconnect=True)
    except pymysql.MySQLError:
        _conn = pymysql.connect(
            host=os.environ["MYSQL_HOST"], user=os.environ["MYSQL_USER"],
            password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DB"],
            connect_timeout=3,
        )
    return _conn

def get_hash(username):
    c = db()
    with c.cursor() as cur:
        cur.execute("SELECT password_hash FROM users WHERE username=%s", (username,))
        row = cur.fetchone()
    return row[0] if row else None
```

In `seed_admin`, use the same shape: `c = db()`, cursor, `execute`, `c.commit()`. Do not wrap `db()` in `with`, or the connection closes again.

## 2. More Auth workers, and a larger Enter Data pool

Bcrypt is CPU-bound and Auth is capped at 0.50 CPU with two Gunicorn workers, so logins queue. Enter Data's pool is hard-coded to 10 connections, so the inserts queue behind that as well.

In `auth/Dockerfile`, change the Gunicorn flag from `-w 2` to `-w 4`.

In `docker-compose.yml`, set Auth's limits to 1.0 CPU and 384 MB (`mem_limit`, `cpus`, and `deploy.resources.limits` all three). Four workers at 256 MB is tight once each holds a MySQL connection.

In `enterdata/index.js`, change `connectionLimit: 10` to `connectionLimit: 30`.

## Results

Measured 22 Oct 2026. `k6 run -e VUS=5 -e DURATION=30s tests/load/k6_test.js`. The second column is after the Auth connection reuse, 4 Gunicorn workers, Auth limit 1 CPU / 384 MB, and Enter Data pool 30. The category index was already in `mysql/init.sh` and was not part of this change.

| Metric | Baseline | After both changes |
|---|---:|---:|
| Requests/sec (k6 `http_reqs`) | 3.81 | 7.39 |
| Error rate % (`http_req_failed`) | 0.82 | 0 |
| p95 latency ms (`http_req_duration`) | 2660 | 1380 |
| Login checks passed % | enterdata 100; showresults 96.7 | 100 |
| Insert checks passed % | 100 | 100 |
| Results checks passed % | 100 | 100 |
| auth CPU peak | 50.88% | 99.52% |
| auth memory peak | 81.96 MiB | 125.5 MiB |
| enterdata CPU peak | 21.73% | 43.70% |
| enterdata memory peak | 81.84 MiB | 33.94 MiB |
| mysql CPU peak | 2.10% | 4.64% |
| mysql memory peak | 437.1 MiB | 438.2 MiB |

VUs: 5. Duration: 30s.
