from stats import apply_stats, compute_stats
from job import scrub


class FakeStats:
    def __init__(self, docs=None):
        self.docs = [dict(d) for d in (docs or [])]

    def update_one(self, filt, update, upsert=False):
        category = filt["category"]
        for doc in self.docs:
            if doc.get("category") == category:
                doc.clear()
                doc.update(update["$set"])
                return
        if upsert:
            self.docs.append(dict(update["$set"]))

    def delete_many(self, filt):
        keep = set(filt["category"]["$nin"])
        self.docs = [d for d in self.docs if d.get("category") in keep]


def by_category(rows):
    return {d["category"]: d for d in compute_stats(rows)}


def test_empty_set():
    assert compute_stats([]) == []


def test_one_row():
    assert compute_stats([("temp", 21.5)]) == [
        {"category": "temp", "min": 21.5, "max": 21.5, "avg": 21.5, "count": 1}
    ]
    assert compute_stats([("level", 0)]) == [
        {"category": "level", "min": 0.0, "max": 0.0, "avg": 0.0, "count": 1}
    ]


def test_many_rows_match_hand_calculation():
    # temp: 10, 20, 30 -> min 10, max 30, avg 20, count 3
    # humidity: 40, 60 -> min 40, max 60, avg 50, count 2
    # pressure: 1, 2, 2 -> min 1, max 2, avg 5/3 = 1.666667, count 3
    rows = [
        ("temp", 10), ("humidity", 40), ("temp", 20), ("pressure", 1),
        ("temp", 30), ("humidity", 60), ("pressure", 2), ("pressure", 2),
    ]
    docs = by_category(rows)
    assert docs["temp"] == {"category": "temp", "min": 10, "max": 30, "avg": 20, "count": 3}
    assert docs["humidity"] == {"category": "humidity", "min": 40, "max": 60, "avg": 50, "count": 2}
    assert docs["pressure"] == {"category": "pressure", "min": 1, "max": 2, "avg": 1.666667, "count": 3}
    assert [d["category"] for d in compute_stats(rows)] == ["humidity", "pressure", "temp"]
    assert compute_stats(rows) == compute_stats(list(rows))


def test_bad_values_are_skipped():
    # Valid temp readings are 10 and -4 only: min -4, max 10, avg 3, count 2.
    # flow keeps 1.5 and 2.5. humidity keeps the single 5.
    # Blank categories, bools, strings, NaN, and infinities are not numbers.
    rows = [
        ("temp", 10), ("temp", None), ("temp", "12"), ("temp", float("nan")),
        ("temp", float("inf")), ("temp", True), ("temp", -4), ("humidity", 5),
        ("", 9), ("  ", 9), (None, 3), ("pressure", float("-inf")),
        ("flow", 1.5), ("flow", 2.5), ("flow", "nope"),
    ]
    docs = by_category(rows)
    assert set(docs) == {"temp", "humidity", "flow"}
    assert docs["temp"] == {"category": "temp", "min": -4, "max": 10, "avg": 3, "count": 2}
    assert docs["humidity"] == {"category": "humidity", "min": 5, "max": 5, "avg": 5, "count": 1}
    assert docs["flow"] == {"category": "flow", "min": 1.5, "max": 2.5, "avg": 2, "count": 2}
    assert "pressure" not in docs


def test_trimmed_category_and_extra_columns():
    # " temp " and "temp" are one category: min 2, max 4, avg 3, count 2.
    rows = [{"category": " temp ", "value": 2}, ("temp", 4, "ignored", 99)]
    assert compute_stats(rows) == [
        {"category": "temp", "min": 2, "max": 4, "avg": 3, "count": 2}
    ]


def test_upsert_replaces_stale_categories():
    store = FakeStats([{"category": "old", "min": 1, "max": 1, "avg": 1, "count": 1, "updated_at": "t0"}])
    docs = compute_stats([("temp", 10), ("temp", 30)])
    assert apply_stats(store, docs, "2026-01-01T00:00:00Z") == 1
    assert store.docs == [{
        "category": "temp", "min": 10, "max": 30, "avg": 20, "count": 2,
        "updated_at": "2026-01-01T00:00:00Z",
    }]
    again = compute_stats([("temp", 10), ("temp", 30)])
    apply_stats(store, again, "2026-01-01T00:00:00Z")
    assert store.docs == [{
        "category": "temp", "min": 10, "max": 30, "avg": 20, "count": 2,
        "updated_at": "2026-01-01T00:00:00Z",
    }]
    apply_stats(store, [], "2026-01-01T00:01:00Z")
    assert store.docs == []


def test_scrub_hides_secrets(monkeypatch):
    monkeypatch.setenv("MYSQL_PASSWORD", "db-password-value")
    monkeypatch.setenv("MONGO_URI", "mongodb://mongo:27017/collector")
    text = scrub(
        "failed mongodb://stats:db-password-value@mongo:27017/collector "
        "password=db-password-value Bearer eyJhbGciOi.secret"
    )
    assert "db-password-value" not in text
    assert "mongodb://stats" not in text
    assert "eyJhbGciOi" not in text
    assert "mongodb://***" in text
