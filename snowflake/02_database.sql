-- =============================================================================
-- 02_database.sql
-- Lakehouse database with Iceberg defaults, then a smoke test that writes one
-- Iceberg table to S3.
--
-- The defaults must exist BEFORE the Openflow connector creates Bronze tables:
-- a Snowflake-managed table keeps the serialization policy in effect when it is
-- created, and it cannot be changed afterwards.
-- =============================================================================

USE ROLE SYSADMIN;

-- A small warehouse for this project only: easy to track cost and to drop later.
-- It suspends after 60 s idle, so it costs nothing while you are not running queries.
CREATE WAREHOUSE IF NOT EXISTS AQ_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'snowflake-open-lakehouse';

USE WAREHOUSE AQ_WH;

CREATE DATABASE IF NOT EXISTS AQ_LAKEHOUSE
  EXTERNAL_VOLUME = 'AQ_ICEBERG_VOL'
  STORAGE_SERIALIZATION_POLICY = COMPATIBLE   -- Parquet that external engines (DuckDB) can read
  ICEBERG_VERSION_DEFAULT = 3                 -- tables we create ourselves (Silver, Gold);
                                              -- the connector takes its version from its own
                                              -- "Iceberg Version" setting: also choose 3 there
  COMMENT = 'snowflake-open-lakehouse: Bronze (Openflow), Silver, Gold';
-- No CATALOG here: at database level it names a catalog integration.
-- Snowflake-managed tables declare CATALOG = 'SNOWFLAKE' themselves.
 
SHOW PARAMETERS IN DATABASE AQ_LAKEHOUSE
  ->> SELECT "key", "value", "level"
      FROM $1
      WHERE "key" IN ('EXTERNAL_VOLUME', 'STORAGE_SERIALIZATION_POLICY', 'ICEBERG_VERSION_DEFAULT');
 
-- Smoke test ------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS AQ_LAKEHOUSE.SMOKE_TEST;
 
CREATE OR REPLACE ICEBERG TABLE AQ_LAKEHOUSE.SMOKE_TEST.HELLO_ICEBERG (
    id    INT,
    note  STRING
)
  CATALOG = 'SNOWFLAKE'
  BASE_LOCATION = 'smoke_test/hello_iceberg';
 
INSERT INTO AQ_LAKEHOUSE.SMOKE_TEST.HELLO_ICEBERG VALUES (1, 'written by Snowflake');
 
SELECT * FROM AQ_LAKEHOUSE.SMOKE_TEST.HELLO_ICEBERG;
 
-- Where the current metadata file lives. Open it in S3 and look for
-- "format-version": 3 to confirm the version default worked.
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('AQ_LAKEHOUSE.SMOKE_TEST.HELLO_ICEBERG');
 
-- Clean up once you have seen the files in S3.
-- DROP SCHEMA AQ_LAKEHOUSE.SMOKE_TEST;