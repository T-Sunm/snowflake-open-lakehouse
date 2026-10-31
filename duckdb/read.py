"""Read the Silver and Gold Iceberg tables with DuckDB through Horizon Catalog.

Run from the repository root:
    uv run scripts/duckdb_read.py

Steps:
    1. exchange the PAT for a short-lived access token (same as check_horizon.py)
    2. give the token to DuckDB as a secret and ATTACH the catalog
    3. run read queries; compare the numbers with the same queries in Snowsight

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


token = get_access_token()

con = duckdb.connect()
con.execute("INSTALL httpfs; LOAD httpfs;")
con.execute("INSTALL iceberg; LOAD iceberg;")

# The token is a secret for DuckDB; it is not printed.
con.execute(f"CREATE OR REPLACE SECRET horizon_secret (TYPE iceberg, TOKEN '{token}')")
con.execute(
    f"""
    ATTACH '{DATABASE}' AS lake (
        TYPE iceberg,
        SECRET horizon_secret,
        URI '{BASE}',
        ACCESS_DELEGATION_MODE 'vended_credentials'
    )
    """
)
print(f"DuckDB {duckdb.__version__} attached catalog {DATABASE} as 'lake'\n")


def show(title: str, sql: str) -> None:
    print(f"-- {title}")
    rows = con.execute(sql).fetchall()
    cols = [d[0] for d in con.description]
    print("   " + " | ".join(cols))
    for r in rows:
        print("   " + " | ".join("NULL" if v is None else str(v) for v in r))
    print()


show("A. Silver rows (Snowflake: 2117)", "SELECT COUNT(*) AS fact_rows FROM lake.SILVER.FACT_AQI")

show(
    "B. The CDC rows (Snowflake: 320 aqi 275, 2118 present, 434 absent)",
    "SELECT measurement_id, aqi, pm25 FROM lake.SILVER.FACT_AQI "
    "WHERE measurement_id IN (320, 434, 2118) ORDER BY measurement_id",
)

show(
    "C. Gold totals (Snowflake: city_ranking 2117)",
    "SELECT SUM(record_count) AS city_ranking_records FROM lake.GOLD.AQI_CITY_RANKING",
)

show(
    "D. Ranking Jan 2021 (Snowflake: Nha Trang has no rank)",
    "SELECT city_name, ROUND(avg_aqi, 1) AS avg_aqi, aqi_rank, days_observed "
    "FROM lake.GOLD.AQI_CITY_RANKING WHERE year = 2021 AND month = 1 "
    "ORDER BY aqi_rank NULLS LAST, city_name",
)
