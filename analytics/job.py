import json, logging, os, re, sys, time
from datetime import datetime, timezone
import pymysql
from pymongo import MongoClient
from stats import apply_stats, compute_stats

logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
log = lambda **kw: logging.info(json.dumps({"svc": "analytics", **kw}, default=str))

HEARTBEAT = os.environ.get("HEARTBEAT_PATH", "/tmp/heartbeat")
REQUIRED = ("MYSQL_HOST", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DB", "MONGO_URI")
_URI = re.compile(r"mongodb(?:\+srv)?://\S+", re.I)
_BEARER = re.compile(r"(?i)\bBearer\s+\S+")
_QUERY = re.compile(r"(?i)\b(password|pwd|token|secret)=([^&\s]+)")


def scrub(text):
    """Drivers sometimes echo a URI or password inside an exception message."""
    text = _URI.sub("mongodb://***", str(text))
    text = _BEARER.sub("Bearer ***", text)
    text = _QUERY.sub(r"\1=***", text)
    for key in ("MYSQL_PASSWORD", "MYSQL_ROOT_PASSWORD", "MONGO_URI", "JWT_SECRET", "ADMIN_PASSWORD"):
        value = os.environ.get(key) or ""
        if len(value) >= 8:
            text = text.replace(value, "***")
    return text[:500]


def touch():
    # No HTTP port is published. The image health check stats this file.
    with open(HEARTBEAT, "w", encoding="utf-8") as fh:
        fh.write(str(int(time.time())))


def sleep_touch(seconds):
    end = time.monotonic() + seconds
    while True:
        touch()
        left = end - time.monotonic()
        if left <= 0:
            return
        time.sleep(min(10, left))


def interval_seconds():
    try:
        value = int(os.environ.get("ANALYTICS_INTERVAL_SECONDS", "30"))
    except ValueError:
        value = 30
    return min(300, max(5, value))


def read_rows():
    conn = pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DB"],
        connect_timeout=3,
        read_timeout=10,
    )
    with conn as c, c.cursor() as cur:
        cur.execute("SELECT category, value FROM measurements")
        return cur.fetchall()


def write_docs(docs):
    with MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=5000, socketTimeoutMS=10000) as client:
        col = client.get_default_database(default="collector")["stats"]
        col.create_index([("category", 1)], unique=True, name="category_unique")
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return apply_stats(col, docs, now)


def run_once():
    log(event="job_start")
    touch()
    rows = read_rows()
    log(event="rows_read", count=len(rows))
    touch()
    written = write_docs(compute_stats(rows))
    log(event="docs_written", count=written)
    touch()


def main():
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        log(event="config_error", missing=missing)
        sys.exit(1)
    interval = interval_seconds()
    backoff = 5
    touch()
    log(event="start", interval=interval)
    while True:
        touch()
        try:
            run_once()
            backoff = 5
        except Exception as exc:
            # A down database must not kill the process. The next pass retries.
            log(event="job_error", error=type(exc).__name__, msg=scrub(exc))
            sleep_touch(backoff)
            backoff = min(backoff * 2, 60)
            continue
        sleep_touch(interval)


if __name__ == "__main__":
    main()
