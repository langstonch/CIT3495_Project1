import math
from numbers import Real


def _number(value):
    # bool is an int; a measurement flag is not a magnitude.
    if isinstance(value, bool) or not isinstance(value, Real):
        return None
    number = float(value)
    if not math.isfinite(number):
        return None
    return number


def _fields(row):
    if isinstance(row, dict):
        return row.get("category"), row.get("value")
    if isinstance(row, (tuple, list)) and len(row) >= 2:
        return row[0], row[1]
    return None, None


def compute_stats(rows):
    """Min, max, average, and count per category. Bad values are left out, not coerced."""
    grouped = {}
    for row in rows:
        category, value = _fields(row)
        if not isinstance(category, str):
            continue
        category = category.strip()
        if not category:
            continue
        number = _number(value)
        if number is None:
            continue
        grouped.setdefault(category, []).append(number)
    docs = []
    for category in sorted(grouped):
        values = grouped[category]
        docs.append({
            "category": category,
            "min": min(values),
            "max": max(values),
            "avg": round(sum(values) / len(values), 6),
            "count": len(values),
        })
    return docs


def apply_stats(collection, docs, updated_at):
    """Upsert current categories and drop the rest so a rerun matches MySQL."""
    categories = []
    for doc in docs:
        categories.append(doc["category"])
        collection.update_one(
            {"category": doc["category"]},
            {"$set": {**doc, "updated_at": updated_at}},
            upsert=True,
        )
    collection.delete_many({"category": {"$nin": categories}})
    return len(categories)
