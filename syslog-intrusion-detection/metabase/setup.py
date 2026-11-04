#!/usr/bin/env python3
"""First-run setup for this folder's Metabase: create the admin user and add the Confluent Cloud data source.

Connection settings and the API key/secret come from `terraform output` (terraform/rtce.tf: service account
syslog-metabase + its API key). MB_DRIVER=lightning (default) or flink; both use the same Global key.
Fallback for the key: CC_GLOBAL_API / CC_GLOBAL_API_SECRET env vars.
Safe to rerun.
"""
import json, os, subprocess, sys, urllib.request, urllib.error

MB = os.environ.get("MB_URL", "http://localhost:3000")
ADMIN_EMAIL = os.environ.get("MB_ADMIN_EMAIL", "admin@example.com")
ADMIN_PASSWORD = os.environ.get("MB_ADMIN_PASSWORD", "Metabase-demo-1")
TF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terraform")


def tf(name):
    try:
        return json.loads(subprocess.check_output(["terraform", f"-chdir={TF}", "output", "-json", name],
                                                  stderr=subprocess.DEVNULL))
    except Exception:
        return None


DB_NAME = "Syslog Confluent Cloud (Flink)" if os.environ.get("MB_DRIVER") == "flink" else "Syslog Confluent Cloud"
MODE = os.environ.get("MB_DRIVER", "lightning")  # lightning (RTCE, Global key) or flink (Flink SQL, Flink key)
if MODE == "flink":
    engine = "confluent-flink"
    conn = tf("metabase_flink") or {  # terraform output not applied: take it from env vars (defaults = this sandbox)
        "cloud": os.environ.get("CC_CLOUD", "aws"), "region": os.environ.get("CC_REGION", "us-east-1"),
        "organization-id": os.environ.get("CC_ORG_ID"), "environment-id": os.environ.get("CC_ENV_ID", "env-7d27kp"),
        "compute-pool-id": os.environ.get("CC_POOL_ID", "lfcp-6k719z2"), "catalog": os.environ.get("CC_ENV_NAME"),
        "database": os.environ.get("CC_CLUSTER_NAME", "sandbox")}
    if not (conn["organization-id"] and conn["catalog"]):
        sys.exit("set CC_ORG_ID and CC_ENV_NAME (environment display name), or apply terraform for metabase_flink")
    # The Global API key is shared with the Lightning driver.
    user, password = tf("metabase_api_key"), tf("metabase_api_secret")
    envkey = ("CC_GLOBAL_API", "CC_GLOBAL_API_SECRET")
else:
    conn, engine = tf("metabase_lightning"), "confluent-lightning"
    user, password = tf("metabase_api_key"), tf("metabase_api_secret")
    envkey = ("CC_GLOBAL_API", "CC_GLOBAL_API_SECRET")
if not conn:
    sys.exit(f"no terraform output for MB_DRIVER={MODE}: run terraform apply in ../terraform first")
if not (user and password):
    user, password = os.environ.get(envkey[0]), os.environ.get(envkey[1])
if not (user and password):
    sys.exit(f"no API key: terraform output, or set {envkey[0]} / {envkey[1]}")
if MODE == "flink":
    details = {**conn, "user": user, "password": password}
else:
    details = {"lightning-endpoint": conn["client.lightning-endpoint"], "environment-id": conn["client.environment-id"],
               "lkc-id": conn["client.lkc-id"], "user": user, "password": password}


def call(method, path, body=None, token=None):
    req = urllib.request.Request(MB + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json", **({"X-Metabase-Session": token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read().decode()[:1500]}")


def login():
    req = urllib.request.Request(MB + "/api/session", method="POST", data=json.dumps(
        {"username": ADMIN_EMAIL, "password": ADMIN_PASSWORD}).encode(), headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))["id"]
    except urllib.error.HTTPError:
        return None


session = login()
if not session:
    token = call("GET", "/api/session/properties")["setup-token"]
    call("POST", "/api/setup", {"token": token, "user": {"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD,
         "first_name": "Demo", "last_name": "Admin", "site_name": "Syslog IDS"},
         "prefs": {"site_name": "Syslog IDS", "allow_tracking": False}})
    print("created admin", ADMIN_EMAIL)
    session = login()

existing = [d for d in call("GET", "/api/database", token=session)["data"] if d["name"] == DB_NAME]
payload = {"name": DB_NAME, "engine": engine, "details": details, "is_full_sync": True,
           "is_on_demand": False, "auto_run_queries": True}
db = call("PUT", f"/api/database/{existing[0]['id']}", payload, session) if existing \
    else call("POST", "/api/database", payload, session)
print("database id", db["id"])
call("POST", f"/api/database/{db['id']}/sync_schema", token=session)
print("sync started; open", MB)
