"""Diagnostic: ask Horizon directly for one table and print its answer.

    uv run scripts/diag_load_table.py [SCHEMA] [TABLE]

Default: SILVER FACT_AQI. The token is never printed.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

DATABASE = "AQ_LAKEHOUSE"
ROLE = "AQ_EXTERNAL"
schema = sys.argv[1] if len(sys.argv) > 1 else "SILVER"
table = sys.argv[2] if len(sys.argv) > 2 else "FACT_AQI"

account = os.environ["SNOWFLAKE_ACCOUNT"]
pat = os.environ["HORIZON_PAT"]
BASE = f"https://{account.lower().replace('_', '-')}.snowflakecomputing.com/polaris/api/catalog"


def call(method, url, headers=None, data=None):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


form = urllib.parse.urlencode(
    {"grant_type": "client_credentials", "scope": f"session:role:{ROLE}", "client_secret": pat}
).encode()
status, body = call(
    "POST", f"{BASE}/v1/oauth/tokens",
    {"Content-Type": "application/x-www-form-urlencoded"}, form,
)
token = json.loads(body)["access_token"]

for label, extra in [
    ("without vended credentials", {}),
    ("with vended credentials", {"X-Iceberg-Access-Delegation": "vended-credentials"}),
]:
    headers = {"Authorization": f"Bearer {token}", **extra}
    status, body = call(
        "GET", f"{BASE}/v1/{DATABASE}/namespaces/{schema}/tables/{table}", headers
    )
    print(f"== {label}: HTTP {status}")
    try:
        doc = json.loads(body)
    except ValueError:
        print(body[:500])
        continue
    if status != 200:
        print(json.dumps(doc, indent=2)[:800])
        continue
    meta = doc.get("metadata", {})
    print("   format-version:", meta.get("format-version"))
    print("   location      :", doc.get("metadata-location"))
    cfg = doc.get("config", {})
    print("   config keys   :", sorted(cfg.keys()))
    print("   storage credentials returned:", "yes" if any("s3" in k.lower() for k in cfg) else "no")
