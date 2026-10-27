-- =============================================================================
-- 01_external_volume.sql
-- External volume: lets Snowflake write Iceberg data and metadata files to your
-- S3 bucket by assuming the IAM role from infra/cloudformation/iceberg-storage.yaml.
--
-- Run in Snowsight, one part at a time:
--   Part A  before updating the CloudFormation stack (pass 1 already deployed)
--   Part B  after the stack update with SnowflakeIamUserArn (pass 2)
--
-- Replace the three <...> values with the stack outputs StorageBaseUrl,
-- RoleArn and ExternalId.
-- =============================================================================

-- Part A ----------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;   -- only ACCOUNTADMIN can create external volumes by default

CREATE EXTERNAL VOLUME IF NOT EXISTS AQ_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (
      NAME = 'aq-s3'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = 's3://aq-lakehouse-733153951784-us-east-2/lakehouse/'          -- e.g. s3://my-bucket/lakehouse/
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::733153951784:role/snowflake-iceberg-aq-iceberg-storage'
      STORAGE_AWS_EXTERNAL_ID = 'snowflake-open-lakehouse'       -- default: snowflake-open-lakehouse
    )
  )
  ALLOW_WRITES = TRUE                                -- required for Snowflake-managed tables
  COMMENT = 'Iceberg storage for snowflake-open-lakehouse';

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