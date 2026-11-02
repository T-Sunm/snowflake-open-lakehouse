-- =============================================================================
-- snowflake/05_horizon_access.sql
-- Access for external engines (DuckDB) through Horizon Catalog.
--
-- One role, one service user, one token:
--   * role  AQ_EXTERNAL       READ on Silver and Gold, READ + WRITE on SANDBOX only
--   * user  AQ_DUCKDB         a SERVICE user (no password, no MFA) that holds the token
--   * an authentication policy that lets this user use a programmatic access
--     token (PAT) without a network policy
--   * the token itself (shown ONCE, in the last result)
--
-- Why Silver and Gold are read-only for this role:
--   Silver only changes through Write-Audit-Publish, and Gold is built from Silver.
--   If an external engine could write to them, it would bypass the Audit step.
--   The external engine gets a SANDBOX schema to write to instead.
--
-- Why a separate user and role instead of TSUNM / OPENFLOW_ADMIN:
--   if the token leaks, it cannot touch Bronze and cannot change Silver or Gold.
--
-- Part A and Part B are safe to re-run. Part C creates the token and must be run
-- once: running it again fails because the token name already exists.
-- =============================================================================

USE WAREHOUSE AQ_WH;

-- Part A: role, user and read access (ACCOUNTADMIN) ---------------------------
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS AQ_EXTERNAL
  COMMENT = 'External engines: read Silver and Gold, read/write SANDBOX';

GRANT USAGE ON DATABASE AQ_LAKEHOUSE        TO ROLE AQ_EXTERNAL;
GRANT USAGE ON SCHEMA   AQ_LAKEHOUSE.SILVER TO ROLE AQ_EXTERNAL;
GRANT USAGE ON SCHEMA   AQ_LAKEHOUSE.GOLD   TO ROLE AQ_EXTERNAL;

-- Iceberg tables are their own object type: "ALL TABLES" does not include them,
-- so the grants must say ICEBERG TABLES.
GRANT SELECT ON ALL ICEBERG TABLES    IN SCHEMA AQ_LAKEHOUSE.SILVER TO ROLE AQ_EXTERNAL;
GRANT SELECT ON ALL ICEBERG TABLES    IN SCHEMA AQ_LAKEHOUSE.GOLD   TO ROLE AQ_EXTERNAL;
GRANT SELECT ON FUTURE ICEBERG TABLES IN SCHEMA AQ_LAKEHOUSE.SILVER TO ROLE AQ_EXTERNAL;
GRANT SELECT ON FUTURE ICEBERG TABLES IN SCHEMA AQ_LAKEHOUSE.GOLD   TO ROLE AQ_EXTERNAL;

-- FACT_AQI and DIM_STATION are cloned into SILVER_CANDIDATE by the Write step.
-- Horizon only hands out storage credentials for a cloned table when the role can
-- also access its clones, so the role gets read access to the candidate schema too.
-- FUTURE grants cover the clones that every pipeline run creates again. This is
-- read-only: the role cannot change the candidate or Silver.
GRANT USAGE ON SCHEMA AQ_LAKEHOUSE.SILVER_CANDIDATE TO ROLE AQ_EXTERNAL;
GRANT SELECT ON ALL ICEBERG TABLES    IN SCHEMA AQ_LAKEHOUSE.SILVER_CANDIDATE TO ROLE AQ_EXTERNAL;
GRANT SELECT ON FUTURE ICEBERG TABLES IN SCHEMA AQ_LAKEHOUSE.SILVER_CANDIDATE TO ROLE AQ_EXTERNAL;

CREATE USER IF NOT EXISTS AQ_DUCKDB
  TYPE = SERVICE
  DEFAULT_ROLE = AQ_EXTERNAL
  COMMENT = 'DuckDB reading and writing Iceberg tables through Horizon Catalog';

GRANT ROLE AQ_EXTERNAL TO USER AQ_DUCKDB;

-- CONTROL is owned by OPENFLOW_ADMIN, so ACCOUNTADMIN needs permission to create
-- an authentication policy there. The owner grants it.
USE ROLE openflow_admin;
GRANT CREATE AUTHENTICATION POLICY ON SCHEMA AQ_LAKEHOUSE.CONTROL TO ROLE ACCOUNTADMIN;
USE ROLE ACCOUNTADMIN;

-- By default a token needs a network policy. For this tutorial we skip it so
-- you can connect from your own machine. In a real account, create a network
-- policy for the machines allowed to use the token instead of using this.
CREATE AUTHENTICATION POLICY IF NOT EXISTS AQ_LAKEHOUSE.CONTROL.AQ_PAT_POLICY
  AUTHENTICATION_METHODS = ('PROGRAMMATIC_ACCESS_TOKEN')
  PAT_POLICY = (NETWORK_POLICY_EVALUATION = ENFORCED_NOT_REQUIRED);

-- A user can hold only one authentication policy, so remove any existing one
-- before setting it. This makes the file safe to re-run.
ALTER USER AQ_DUCKDB UNSET AUTHENTICATION POLICY;
ALTER USER AQ_DUCKDB SET AUTHENTICATION POLICY AQ_LAKEHOUSE.CONTROL.AQ_PAT_POLICY;

-- Part B: the SANDBOX schema (OPENFLOW_ADMIN) ---------------------------------
-- The table is created and owned by OPENFLOW_ADMIN, the role that already has
-- USAGE on the external volume. Horizon needs the table OWNER to have it, or
-- DuckDB's requests for storage credentials fail.
USE ROLE openflow_admin;
USE DATABASE AQ_LAKEHOUSE;

CREATE SCHEMA IF NOT EXISTS AQ_LAKEHOUSE.SANDBOX;

CREATE ICEBERG TABLE IF NOT EXISTS AQ_LAKEHOUSE.SANDBOX.DUCKDB_NOTES (
    note_id     NUMBER(38,0),
    note        STRING,
    written_by  STRING,
    written_at  TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'sandbox/duckdb_notes';

GRANT USAGE ON SCHEMA AQ_LAKEHOUSE.SANDBOX TO ROLE AQ_EXTERNAL;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON TABLE AQ_LAKEHOUSE.SANDBOX.DUCKDB_NOTES TO ROLE AQ_EXTERNAL;

-- Check: what the role can do.
-- Expected: SELECT on the five Silver and five Gold tables and on the two tables
-- of SILVER_CANDIDATE; SELECT, INSERT, UPDATE, DELETE, TRUNCATE on
-- SANDBOX.DUCKDB_NOTES; no write privilege on Silver or Gold.
SHOW GRANTS TO ROLE AQ_EXTERNAL;

-- Part C: the token (ACCOUNTADMIN) --------------------------------------------
-- The secret appears ONLY in the result of this statement (column token_secret):
-- copy it straight into your .env file as HORIZON_PAT.
-- Never paste it into chat, a ticket or a commit.
--
-- Lost it? Remove and create again:
--   ALTER USER AQ_DUCKDB REMOVE PAT duckdb_token;
USE ROLE ACCOUNTADMIN;

ALTER USER AQ_DUCKDB ADD PAT duckdb_token
  ROLE_RESTRICTION = 'AQ_EXTERNAL'
  DAYS_TO_EXPIRY = 30
  COMMENT = 'DuckDB tutorial token';