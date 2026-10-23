import json, logging, os, sys, time
import bcrypt, jwt, pymysql
from flask import Flask, jsonify, request

JWT_SECRET = os.environ["JWT_SECRET"]
TTL = int(os.environ.get("TOKEN_TTL_SECONDS", "3600"))
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
log = lambda **kw: logging.info(json.dumps({"svc": "auth", **kw}))
app = Flask(__name__)
DUMMY = bcrypt.hashpw(b"x", bcrypt.gensalt()).decode()


def db():
    return pymysql.connect(host=os.environ["MYSQL_HOST"], user=os.environ["MYSQL_USER"],
                           password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DB"],
                           connect_timeout=3)


def get_hash(username):
    with db() as c, c.cursor() as cur:
        cur.execute("SELECT password_hash FROM users WHERE username=%s", (username,))
        row = cur.fetchone()
    return row[0] if row else None


def seed_admin():
    """Create the first user from env if missing (needs INSERT on users)."""
    u, p = os.environ.get("ADMIN_USER"), os.environ.get("ADMIN_PASSWORD")
    if not (u and p):
        return
    for i in range(30):  # wait for MySQL
        try:
            if get_hash(u) is None:
                h = bcrypt.hashpw(p.encode(), bcrypt.gensalt()).decode()
                with db() as c, c.cursor() as cur:
                    cur.execute("INSERT INTO users (username, password_hash) VALUES (%s,%s)", (u, h))
                    c.commit()
                log(event="seeded_user", user=u)
            return
        except pymysql.MySQLError as e:
            log(event="seed_retry", err=str(e.args[0]))
            time.sleep(2)


@app.get("/health")
def health():
    try:
        db().close()
    except pymysql.MySQLError:
        return jsonify(status="db_down"), 503
    return jsonify(status="ok")


@app.post("/login")
def login():
    b = request.get_json(silent=True) or {}
    u, p = b.get("username"), b.get("password")
    if not (isinstance(u, str) and isinstance(p, str) and 0 < len(u) <= 64 and 0 < len(p) <= 72):
        return jsonify(error="bad request"), 400
    try:
        h = get_hash(u)
    except pymysql.MySQLError:
        log(event="db_error")
        return jsonify(error="unavailable"), 503
    # always run bcrypt so unknown users cost the same as wrong passwords
    ok = bcrypt.checkpw(p.encode(), (h or DUMMY).encode()) and h is not None
    if not ok:
        log(event="login_fail", user=u[:64])
        return jsonify(error="invalid credentials"), 401
    now = int(time.time())
    log(event="login_ok", user=u)
    return jsonify(token=jwt.encode({"sub": u, "iat": now, "exp": now + TTL}, JWT_SECRET, "HS256"))


@app.get("/validate")
def validate():
    t = request.headers.get("Authorization", "")[7:]
    try:
        c = jwt.decode(t, JWT_SECRET, algorithms=["HS256"])
    except jwt.PyJWTError:
        return jsonify(error="invalid token"), 401
    return jsonify(user=c["sub"])
