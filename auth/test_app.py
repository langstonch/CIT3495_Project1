import os
os.environ["JWT_SECRET"] = "test-secret"
import bcrypt, jwt, time
import app as a

H = bcrypt.hashpw(b"pw123", bcrypt.gensalt(4)).decode()
a.get_hash = lambda u: H if u == "alice" else None
c = a.app.test_client()
post = lambda **b: c.post("/login", json=b)


def test_login_ok_and_validate():
    t = post(username="alice", password="pw123").json["token"]
    r = c.get("/validate", headers={"Authorization": "Bearer " + t})
    assert r.status_code == 200 and r.json["user"] == "alice"


def test_bad_credentials():
    assert post(username="alice", password="nope").status_code == 401
    assert post(username="bob", password="pw123").status_code == 401


def test_bad_input():
    assert post(username="alice").status_code == 400
    assert post(username=["a"], password="x").status_code == 400
    assert c.post("/login", data="junk").status_code == 400


def test_token_rejected():
    v = lambda t: c.get("/validate", headers={"Authorization": "Bearer " + t}).status_code
    assert v("") == 401 and v("garbage") == 401
    assert v(jwt.encode({"sub": "x", "exp": int(time.time()) - 5}, "test-secret", "HS256")) == 401
    assert v(jwt.encode({"sub": "x", "exp": int(time.time()) + 60}, "wrong", "HS256")) == 401
    assert v(jwt.encode({"sub": "x"}, "", "none")) == 401
