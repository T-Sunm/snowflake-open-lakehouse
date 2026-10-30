"""Run the whole Write-Audit-Publish cycle with one command.

    uv run wap/run.py

    1. WRITE    wap/01_write_candidate.sql   build Silver Candidate from Bronze
    2. AUDIT    wap/02_audit.py              Soda checks on the candidate
    3. PUBLISH  wap/03_publish.sql           only if the audit did not fail
    4. GOLD     wap/04_load_gold.sql         aggregates built from the new Silver

If the audit fails, Publish and Gold do not run and Current Silver stays exactly
as it was. Exit code: 0 done, 1 audit failed (nothing published), 2 error.

Each .sql file may end with a block of manual checks that starts with a line
beginning "-- CHECKS". Only the part before that line is run here.
"""

import os
import subprocess
import sys
from pathlib import Path

import snowflake.connector
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
WAP = ROOT / "wap"
MANUAL_CHECKS_MARKER = "\n-- CHECKS"


def connect() -> snowflake.connector.SnowflakeConnection:
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key_file=str(ROOT / os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]),
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database="AQ_LAKEHOUSE",
    )


def run_sql_file(path: Path) -> None:
    sql = path.read_text(encoding="utf-8")
    sql = sql.split(MANUAL_CHECKS_MARKER, 1)[0]
    conn = connect()
    try:
        # remove_comments: comment lines contain ';' and a trailing comment-only
        # chunk would otherwise be sent to Snowflake as an empty statement.
        for cursor in conn.execute_string(sql, remove_comments=True):
            cursor.close()
    finally:
        conn.close()


def main() -> int:
    load_dotenv(ROOT / ".env")

    print("== 1/4 WRITE: build Silver Candidate from Bronze")
    try:
        run_sql_file(WAP / "01_write_candidate.sql")
    except Exception as exc:
        print(f"WRITE failed: {exc}")
        return 2

    print("== 2/4 AUDIT: Soda checks on the candidate")
    audit = subprocess.run([sys.executable, str(WAP / "02_audit.py")], cwd=ROOT)
    if audit.returncode == 1:
        print("== Audit failed. Nothing was published; Current Silver is unchanged.")
        return 1
    if audit.returncode != 0:
        print("== Audit could not run. Nothing was published.")
        return 2

    print("== 3/4 PUBLISH: candidate becomes Current Silver")
    try:
        run_sql_file(WAP / "03_publish.sql")
    except Exception as exc:
        print(f"PUBLISH failed: {exc}")
        return 2

    print("== 4/4 GOLD: rebuild aggregates from the new Silver")
    try:
        run_sql_file(WAP / "04_load_gold.sql")
    except Exception as exc:
        print(f"GOLD failed (Silver was already published): {exc}")
        return 2

    print("== Done. Silver and Gold are updated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
