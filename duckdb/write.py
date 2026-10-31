"""Write to an Iceberg table with DuckDB through Horizon Catalog.

Run from the repository root:
    uv run duckdb/write.py

DuckDB inserts, updates and deletes rows in SANDBOX.DUCKDB_NOTES, printing the
table after each step. Afterwards, read the same table in Snowsight (the query is
printed at the end) and compare.

Optional: add --try-silver to also try a write to Silver. The role only has SELECT
on Silver, so the write should be refused (observed: HTTP 403 when uploading the
data file to S3). If the refusal did not happen, a duplicate row would land in
SILVER.DIM_CITY.

The PAT and the access token are never printed.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import duckdb
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

DATABASE = "AQ_LAKEHOUSE"
ROLE = "AQ_EXTERNAL"
TABLE = "lake.SANDBOX.DUCKDB_NOTES"

account = os.environ.get("SNOWFLAKE_ACCOUNT", "")
pat = os.environ.get("HORIZON_PAT", "")
if not account or not pat:
    sys.exit("Missing SNOWFLAKE_ACCOUNT or HORIZON_PAT in .env")

host = account.lower().replace("_", "-")
BASE = f"https://{host}.snowflakecomputing.com/polaris/api/catalog"


def get_access_token() -> str:
    form = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "scope": f"session:role:{ROLE}",
            "client_secret": pat,
        }
    ).encode()
    req = urllib.request.Request(
        f"{BASE}/v1/oauth/tokens",
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=form,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())["access_token"]
    except urllib.error.HTTPError as e:
        sys.exit(f"Token exchange failed: HTTP {e.code}")


con = duckdb.connect()
con.execute("INSTALL httpfs; LOAD httpfs;")
con.execute("INSTALL iceberg; LOAD iceberg;")
con.execute(f"CREATE OR REPLACE SECRET horizon_secret (TYPE iceberg, TOKEN '{get_access_token()}')")

# DISABLE_MULTI_TABLE_COMMIT: Horizon does not support the multi-table commit
# endpoint, so DuckDB must commit table by table.
con.execute(
    f"""
    ATTACH '{DATABASE}' AS lake (
        TYPE iceberg,
        SECRET horizon_secret,
        URI '{BASE}',
        ACCESS_DELEGATION_MODE 'vended_credentials',
        DISABLE_MULTI_TABLE_COMMIT true
    )
    """
)
print(f"DuckDB {duckdb.__version__} attached catalog {DATABASE} as 'lake'\n")


def show(title: str) -> None:
    print(f"-- {title}")
    rows = con.execute(f"SELECT * FROM {TABLE} ORDER BY note_id").fetchall()
    cols = [d[0] for d in con.description]
    print("   " + " | ".join(cols))
    for r in rows:
        print("   " + " | ".join("NULL" if v is None else str(v) for v in r))
    if not rows:
        print("   (empty)")
    print()


# 0. Start from an empty table so the script can be run again.
con.execute(f"DELETE FROM {TABLE}")
show("0. Empty table")

# 1. INSERT
con.execute(
    f"""
    INSERT INTO {TABLE} VALUES
        (1, 'first note from DuckDB',  'duckdb', CAST(now() AS TIMESTAMP)),
        (2, 'second note from DuckDB', 'duckdb', CAST(now() AS TIMESTAMP)),
        (3, 'third note from DuckDB',  'duckdb', CAST(now() AS TIMESTAMP))
    """
)
show("1. After INSERT of 3 rows")

# 2. UPDATE
con.execute(f"UPDATE {TABLE} SET note = 'second note, edited by DuckDB' WHERE note_id = 2")
show("2. After UPDATE of note 2")

# 3. DELETE
con.execute(f"DELETE FROM {TABLE} WHERE note_id = 3")
show("3. After DELETE of note 3")

print("Now read the same table in Snowsight and compare:")
print("    SELECT * FROM AQ_LAKEHOUSE.SANDBOX.DUCKDB_NOTES ORDER BY note_id;")
print("Expected: 2 rows: note 1, and note 2 with the edited text.\n")

# 4. Optional: a write to Silver must be refused.
if "--try-silver" in sys.argv:
    print("-- 4. Trying to write to Silver (must be refused)")
    try:
        con.execute("INSERT INTO lake.SILVER.DIM_CITY SELECT * FROM lake.SILVER.DIM_CITY LIMIT 1")
        print("   !! The write SUCCEEDED. A duplicate row is now in SILVER.DIM_CITY.")
        print("   !! Tell me before doing anything else.")
    except duckdb.Error as e:
        print(f"   Refused, as expected: {str(e)[:200]}")