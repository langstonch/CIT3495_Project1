# C6 — Persistence

Named volumes `mysql_data` and `mongo_data` are declared in `docker-compose.yml`. `mysql/init.sh` runs only when the MySQL data directory is empty, so recreating the container does not rebuild the tables or wipe the rows.

```powershell
pwsh scripts/test_persistence.ps1
```

```bash
bash scripts/test_persistence.sh
```

The script inserts four rows in category `persist-check`, waits until the analytics job upserts a `stats` document whose `count` equals the SQL count, then runs:

```text
docker compose rm -sf mysql mongo
docker compose up -d mysql mongo
```

There is no `-v`. The script refuses to remove containers if the stats document never matches. Paste its table here.

Measured 22 Oct 2026. Both databases were healthy 7s after recreate. Counts matched.

| Count | Before rm | After recreate | Match |
|---|---:|---:|---|
| MySQL measurements | 8 | 8 | yes |
| MySQL users | 1 | 1 | yes |
| MySQL rows in persist-check | 8 | 8 | yes |
| Mongo stats count for persist-check | 8 | 8 | yes |
| Mongo stats documents | 1 | 1 | yes |

A pass is every Match cell reading `yes`.
