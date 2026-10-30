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
-- RoleArn and ExternalId. Fill them in only in your Snowsight copy; keep the
-- <...> placeholders in the repo file.
-- =============================================================================

-- Part A ----------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;   -- only ACCOUNTADMIN can create external volumes by default

CREATE EXTERNAL VOLUME IF NOT EXISTS AQ_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (
      NAME = 'aq-s3'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = '<StorageBaseUrl>'             -- e.g. s3://my-bucket/lakehouse/
      STORAGE_AWS_ROLE_ARN = '<RoleArn>'                -- e.g. arn:aws:iam::<account-id>:role/snowflake-iceberg-aq-iceberg-storage
      STORAGE_AWS_EXTERNAL_ID = '<ExternalId>'          -- default: snowflake-open-lakehouse
    )
  )
  ALLOW_WRITES = TRUE                                   -- required for Snowflake-managed tables
  COMMENT = 'Iceberg storage for snowflake-open-lakehouse';

-- Copy snowflake_iam_user_arn from this result into the CloudFormation
-- parameter SnowflakeIamUserArn (second deploy). Its account number belongs to
-- Snowflake, not to you.
DESC EXTERNAL VOLUME AQ_ICEBERG_VOL
  ->> SELECT
        PARSE_JSON("property_value"):STORAGE_AWS_IAM_USER_ARN::STRING AS snowflake_iam_user_arn,
        PARSE_JSON("property_value"):STORAGE_AWS_EXTERNAL_ID::STRING  AS external_id
      FROM $1
      WHERE "parent_property" = 'STORAGE_LOCATIONS'
        AND "property" LIKE 'STORAGE_LOCATION_%';

-- Part B ----------------------------------------------------------------------
-- Run after the second CloudFormation deploy (TrustReady = true).
-- Expect "success":true with write, read, list and delete all PASSED.
-- If it fails, wait about a minute and run it again: trust policy changes take
-- a few seconds to apply.
SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('AQ_ICEBERG_VOL');

-- 02_database.sql runs as SYSADMIN, which needs the volume to set it as a
-- database default.
GRANT USAGE ON EXTERNAL VOLUME AQ_ICEBERG_VOL TO ROLE SYSADMIN;