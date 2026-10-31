"""Check that an external client can reach the Horizon Iceberg REST catalog.

Run from the repository root:
    uv run scripts/check_horizon.py

It reads .env and does four things, printing one line per step:
    1. exchange the PAT for a short-lived access token (scoped to the AQ_EXTERNAL role)
    2. ask the catalog for its configuration
    3. list the namespaces (schemas) the role can see
    4. list the tables in each namespace

Only the Python standard library and python-dotenv are used. The PAT and the
access token are never printed.
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

account = os.environ.get("SNOWFLAKE_ACCOUNT", "")
pat = os.environ.get("HORIZON_PAT", "")
if not account or not pat:
    sys.exit("Missing SNOWFLAKE_ACCOUNT or HORIZON_PAT in .env")

# <organization>-<account> becomes a lower-case host name
host = account.lower().replace("_", "-")
BASE = f"https://{host}.snowflakecomputing.com/polaris/api/catalog"


def call(method, url, *, headers=None, data=None):
    """Return (status, parsed JSON or raw text). Never raises on HTTP errors."""
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            status = resp.status
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        status = e.code
    try:
        return status, json.loads(body)
    except ValueError:
        return status, body


print(f"Endpoint: {BASE}")

# 1. PAT -> access token
form = urllib.parse.urlencode(
    {
        "grant_type": "client_credentials",
        "scope": f"session:role:{ROLE}",
        "client_secret": pat,
    }
).encode()
status, body = call(
    "POST",
    f"{BASE}/v1/oauth/tokens",
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    data=form,
)
if status != 200 or not isinstance(body, dict) or "access_token" not in body:
    print(f"[FAIL] token exchange: HTTP {status}")
    print(body if not isinstance(body, dict) else {k: v for k, v in body.items() if k != "access_token"})
    sys.exit(1)
print("[PASS] token exchange")

auth = {
    "Authorization": f"Bearer {body['access_token']}",
    "X-Iceberg-Access-Delegation": "vended-credentials",
}

# 2. catalog configuration
status, cfg = call("GET", f"{BASE}/v1/config?warehouse={DATABASE}", headers=auth)
if status != 200:
    print(f"[FAIL] catalog config: HTTP {status}")
    print(cfg)
    sys.exit(1)
prefix = (cfg.get("overrides") or {}).get("prefix") or DATABASE
print(f"[PASS] catalog config (prefix: {prefix})")

# 3. namespaces
status, body = call("GET", f"{BASE}/v1/{prefix}/namespaces", headers=auth)
if status != 200:
    print(f"[FAIL] list namespaces: HTTP {status}")
    print(body)
    sys.exit(1)
namespaces = [".".join(n) for n in body.get("namespaces", [])]
print(f"[PASS] namespaces: {', '.join(namespaces) or '(none)'}")

# 4. tables in each namespace
total = 0
for ns in namespaces:
    status, body = call("GET", f"{BASE}/v1/{prefix}/namespaces/{ns}/tables", headers=auth)
    if status != 200:
        print(f"[FAIL] list tables in {ns}: HTTP {status}")
        print(body)
        continue
    names = [t["name"] for t in body.get("identifiers", [])]
    total += len(names)
    print(f"  {ns}: {len(names)} tables  {', '.join(names)}")

print(f"\n== Horizon is reachable. {total} tables visible to role {ROLE}.")
