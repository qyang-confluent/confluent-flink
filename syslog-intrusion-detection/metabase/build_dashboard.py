#!/usr/bin/env python3
"""Create (or recreate) the 'Syslog IDS' dashboard in the local Metabase on `syslog_alerts`.

Metabase is the one in this folder (start.sh; public Confluent JDBC driver over Flink SQL snapshot queries, http://localhost:3000). Resync first
(`POST /api/database/<id>/sync_schema`, or rerun that folder's setup.py). Mirrors the Zeppelin note
"syslog IDS with Steamhouse" (stacked chart of the alert archive) and adds KPI tiles and an attack table.
"""
import json, os, sys, urllib.request, urllib.error

MB = os.environ.get("MB_URL", "http://localhost:3000")
EMAIL = os.environ.get("MB_ADMIN_EMAIL", "admin@example.com")
PASSWORD = os.environ.get("MB_ADMIN_PASSWORD", "Metabase-demo-1")
FLINK = os.environ.get("MB_DRIVER") == "flink"
DASH = "Syslog IDS (Flink)" if FLINK else "Syslog IDS"
DB_NAME = "Syslog Confluent Cloud (Flink)" if FLINK else "Syslog Confluent Cloud"
S = None


def call(method, path, body=None):
    req = urllib.request.Request(MB + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"X-Metabase-Session": S} if S else {})})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read().decode()[:1500]}")


S = call("POST", "/api/session", {"username": EMAIL, "password": PASSWORD})["id"]
db = next(d for d in call("GET", "/api/database")["data"] if d["name"] == DB_NAME)
meta = call("GET", f"/api/database/{db['id']}/metadata")
table = next((t for t in meta["tables"] if t["name"] == "syslog_alerts"), None)
if not table:
    sys.exit("syslog_alerts not synced: create the table, then POST /api/database/<id>/sync_schema")
F = {f["name"].upper(): f["id"] for f in table["fields"]}  # Flink columns are lower case
fld = lambda n, **o: ["field", F[n.upper()], o or None]
SRC = {"source-table": table["id"]}
ATTACK = ["=", fld("VERDICT"), "attack"]

cards = [  # (name, display, query, size (w,h), viz settings)
    ("Windows scored", "scalar", {**SRC, "aggregation": [["count"]]}, (6, 3), {}),
    ("Attack windows", "scalar", {**SRC, "aggregation": [["count"]], "filter": ATTACK}, (6, 3), {}),
    ("Attacking hosts", "scalar", {**SRC, "aggregation": [["distinct", fld("HOST")]], "filter": ATTACK}, (6, 3), {}),
    ("Avg attack confidence", "scalar", {**SRC, "aggregation": [["avg", fld("CONFIDENCE")]], "filter": ATTACK}, (6, 3), {}),
    ("Windows by verdict", "pie", {**SRC, "aggregation": [["count"]], "breakout": [fld("VERDICT")]}, (6, 5), {}),
    ("Attacks by category", "bar", {**SRC, "aggregation": [["count"]], "breakout": [fld("CATEGORY")], "filter": ATTACK}, (6, 5), {}),
    ("Log lines per window by category", "area", {**SRC, "aggregation": [["sum", fld("LINE_COUNT")]],
        "breakout": [fld("WINDOW_START", **{"temporal-unit": "default"}), fld("CATEGORY")], "order-by": [["asc", fld("WINDOW_START")]]}, (24, 6),
        {"stackable.stack_type": "stacked", "graph.dimensions": ["window_start", "category"], "graph.metrics": ["sum"]}),
    ("Attack windows by host", "row", {**SRC, "aggregation": [["count"]], "breakout": [fld("HOST")], "filter": ATTACK,
        "order-by": [["desc", ["aggregation", 0]]], "limit": 10}, (8, 5), {}),
    ("Latest attack windows", "table", {**SRC, "filter": ATTACK, "order-by": [["desc", fld("WINDOW_START")]], "limit": 25,
        "fields": [fld(n) for n in ("WINDOW_START", "HOST", "CATEGORY", "CONFIDENCE", "LINE_COUNT", "REASON", "SAMPLE")]},
        (16, 5), {}),
]

for d in [d for d in call("GET", "/api/dashboard") if d["name"] == DASH]:
    call("DELETE", f"/api/dashboard/{d['id']}")
names = {c[0] for c in cards}
for c in call("GET", "/api/card"):
    if c["name"] in names and c["database_id"] == db["id"]:
        call("PUT", f"/api/card/{c['id']}", {"archived": True})
dash = call("POST", "/api/dashboard", {"name": DASH, "description": "LLM-scored syslog windows from Kafka (Flink ML_PREDICT)"})

dashcards, row, col = [], 0, 0
for i, (name, display, query, (w, h), viz) in enumerate(cards):
    r = call("POST", "/api/dataset", {"database": db["id"], "type": "query", "query": query})
    if r.get("status") != "completed":
        print("FAILED", name, r.get("error")); continue
    card = call("POST", "/api/card", {"name": name, "display": display, "visualization_settings": viz,
        "dataset_query": {"database": db["id"], "type": "query", "query": query}})
    print(f"ok  {name}: {len(r['data']['rows'])} rows")
    if col + w > 24:
        row, col = row + h, 0
    dashcards.append({"id": -(i + 1), "card_id": card["id"], "row": row, "col": col, "size_x": w, "size_y": h,
                      "visualization_settings": {}, "parameter_mappings": []})
    col += w
call("PUT", f"/api/dashboard/{dash['id']}", {"dashcards": dashcards})
uuid = call("POST", f"/api/dashboard/{dash['id']}/public_link")["uuid"]
print(f"{MB}/dashboard/{dash['id']}  (login required)")
print(f"{MB}/public/dashboard/{uuid}  (no login)")
