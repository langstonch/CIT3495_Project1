# CIT3495 Project 1: Data Collection and Analytics

Six containers: a login service, two web apps, a stats job, MySQL, and MongoDB. Enter Data and Show Results are the only services published on the host. Everything else stays on the private `backend` network.

Enter a category and a number at [http://localhost:3001](http://localhost:3001). Within about 30 seconds the analytics job rolls that row into per-category min, max, average, and count. View the rollup at [http://localhost:3002](http://localhost:3002). Both apps require the admin user created from `.env`.

## Run from a clean machine

Docker Desktop (or another engine with Compose v2) is required.

```powershell
copy .env.example .env
# Replace every placeholder in .env before a shared or graded run.
docker compose up --build
```

Stop and keep the data: `docker compose down`. Add `-v` to delete the `mysql_data` and `mongo_data` volumes.

Sign in on either site as `ADMIN_USER` / `ADMIN_PASSWORD` from `.env`. The example values are `admin` / `change_this_password`.

| URL | What it is |
|---|---|
| http://localhost:3001 | Enter Data. Writes one measurement per submit. |
| http://localhost:3002 | Show Results. Reads the MongoDB `stats` collection. |
| http://localhost:3001/health and :3002/health | Public liveness checks. No login. |

`auth` (port 5000), `analytics`, MySQL (3306), and MongoDB (27017) do not publish host ports. `docker ps` should show only `3001` and `3002`.

## What is running

| Service | Build | Host port | Health | Role |
|---|---|---|---|---|
| mysql | `mysql:8.4` plus `mysql/init.sh` | none | `mysqladmin ping` | Users and raw measurements. Volume `mysql_data`. |
| mongo | `mongo:7` | none | `mongosh` ping | One `stats` document per category. Volume `mongo_data`. |
| auth | `./auth` (Python, Flask, gunicorn) | none | `GET /health` | `POST /login`, `GET /validate`. HS256 JWT, 1 hour. |
| enterdata | `./enterdata` (Node, Express) | 3001 | `GET /health` | Login form and measurement insert. |
| analytics | `./analytics` (Python) | none | heartbeat file | Every 30s: read MySQL, upsert Mongo. No HTTP port. |
| showresults | `./showresults` (Node, Express) | 3002 | `GET /health` | Login form and stats table. |

`frontend` is a normal bridge and holds the two web apps. `backend` is a bridge with `internal: true`, so MySQL, MongoDB, auth, and analytics are not reachable from the host and cannot open outbound connections. The web apps join both networks.

Startup order is `depends_on` with `condition: service_healthy`: auth waits for MySQL, Enter Data waits for auth, analytics waits for MySQL and MongoDB, Show Results waits for MongoDB and auth.

MySQL is limited to 1 CPU and 512 MB (InnoDB fails first-init under the default buffer). MongoDB is 0.75 CPU and 512 MB. Auth and analytics are 0.50 CPU and 256 MB each. Every service restarts unless stopped.

## Data contract

Auth: `POST /login` with `{username, password}` returns `{token}` (400 bad input, 401 bad credentials). `GET /validate` with `Authorization: Bearer <token>` returns `{user}` or 401. Both apps send that token in an `HttpOnly; SameSite=Strict` cookie.

MySQL database `analytics_db` (from `MYSQL_DATABASE`):

- `users(id, username UNIQUE, password_hash)` — account `auth` can SELECT and INSERT.
- `measurements(id, user, category, value DOUBLE, created_at)` — account `enterdata` can INSERT only; account `analytics` can SELECT only.

`MYSQL_USER=app_user` in `.env.example` is the shared name from the assignment sheet. The running containers do not log in as that user. Compose gives each service the account above, using `AUTH_DB_PASSWORD`, `ENTERDATA_DB_PASSWORD`, and `ANALYTICS_DB_PASSWORD`. App code reads the database name from `MYSQL_DB`, which Compose sets from `MYSQL_DATABASE`.

MongoDB database `analytics_db` (the path on `MONGO_URI`), collection `stats`: `{category, min, max, avg, count, updated_at}`, one document per category, replaced on each run. The job is idempotent. If MySQL or MongoDB is down it logs and retries with backoff instead of exiting.

## Tests

From each service directory, on the host (not inside Compose):

```powershell
cd auth; pip install -r requirements.txt; pytest
cd enterdata; npm install; npm test
cd analytics; pip install -r requirements.txt; pytest
cd showresults; npm install; npm test
```

Auth has 4 tests, Enter Data 3, analytics 7, Show Results 6.

## Layout

```
docker-compose.yml          full stack
.env.example                placeholders; copy to .env (git-ignored)
auth/  enterdata/  analytics/  showresults/  mysql/
compose-slices/             Part A and Part B compose files, kept for reference
docs/assignment/            assignment prompt
```

The slice files are not the supported start path. From the repo root they need the root env file:

```powershell
docker compose --env-file .env -f compose-slices/compose.partA.yml up -d --build
docker compose --env-file .env -f compose-slices/compose.partA.yml -f compose-slices/compose.partB.yml up -d --build
```

Those files default the database to `collector` only when `MYSQL_DATABASE` is unset. Do not point them at a volume that was initialized under a different database name.

## Security notes

Passwords are bcrypt-hashed, and an unknown username still runs a bcrypt compare. SQL and Mongo queries are parameterized. Category and value are checked on the server before insert. HTML from the database is escaped. Responses set `nosniff`, `DENY` framing, and a tight Content-Security-Policy. Images do not contain secrets. Auth and analytics run as uid 10001; the Node apps run as the image `node` user. Logs are JSON and are written so they do not include passwords, tokens, or connection strings.

Not in this stack: login rate limiting, TLS (terminate at a proxy if required), and a separate CSRF token. `SameSite=Strict` covers the cookie case for these forms.
