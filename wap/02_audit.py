"""AUDIT step of Write-Audit-Publish.

Runs the Soda checks in soda/checks/silver_candidate.yml against the Silver
Candidate, prints every result, and logs them to CONTROL.DQ_RESULTS.

Exit code:
    0  every check passed, or only warnings (Publish may run)
    1  at least one check failed (Publish must NOT run)
    2  Soda could not run (configuration, connection or check syntax error)

Usage (from the repository root):
    uv run wap/02_audit.py
"""

import os
import sys
import uuid
from pathlib import Path

import snowflake.connector
from dotenv import load_dotenv
from soda.scan import Scan

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "soda" / "configuration.yml"
CHECKS = ROOT / "soda" / "checks" / "silver_candidate.yml"


def run_soda() -> Scan:
    scan = Scan()
    scan.set_scan_definition_name("silver_candidate")
    scan.set_data_source_name("aq")
    scan.add_configuration_yaml_file(str(CONFIG))
    scan.add_sodacl_yaml_file(str(CHECKS))
    scan.execute()
    return scan


def log_results(run_id: str, checks: list[dict]) -> None:
    """Write one row per check to CONTROL.DQ_RESULTS.

    severity holds the Soda outcome: 'pass', 'warn' (does not block Publish)
    or 'fail' (blocks Publish).
    """
    rows = []
    for check in checks:
        outcome = check.get("outcome") or "unknown"
        diagnostics = check.get("diagnostics") or {}
        rows.append(
            (
                run_id,
                "silver_candidate",
                check.get("name") or "unnamed check",
                outcome,
                outcome == "pass",
                str(diagnostics)[:2000],
            )
        )

    conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key_file=os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database="AQ_LAKEHOUSE",
    )
    try:
        conn.cursor().executemany(
            "INSERT INTO CONTROL.DQ_RESULTS "
            "(run_id, layer, check_name, severity, passed, detail) "
            "VALUES (%s, %s, %s, %s, %s, %s)",
            rows,
        )
    finally:
        conn.close()


def main() -> int:
    load_dotenv(ROOT / ".env")
    run_id = str(uuid.uuid4())

    scan = run_soda()

    if scan.has_error_logs():
        print("AUDIT ERROR: Soda could not run.")
        print(scan.get_error_logs_text())
        return 2

    results = scan.get_scan_results()
    checks = results.get("checks", [])

    print(f"Audit run {run_id}")
    for check in checks:
        print(f"  [{(check.get('outcome') or '?').upper():4}] {check.get('name')}")

    try:
        log_results(run_id, checks)
    except Exception as exc:  # logging must never hide the audit verdict
        print(f"WARNING: could not write CONTROL.DQ_RESULTS: {exc}")

    if scan.has_check_fails():
        print("AUDIT FAILED: Silver Candidate is not published.")
        return 1

    if scan.has_check_warns():
        print("AUDIT PASSED with warnings.")
    else:
        print("AUDIT PASSED.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
