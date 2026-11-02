-- 02b_openflow_access.sql
-- Roles, privileges and secret for Openflow BYOC. Safe to re-run.
-- Requires: AQ_LAKEHOUSE, AQ_WH, AQ_ICEBERG_VOL (01_external_volume.sql, 02_database.sql).
-- After running: sign out and back in to Snowsight so the new default role takes effect.

USE ROLE ACCOUNTADMIN;
SET me = CURRENT_USER();

-- Openflow admin role
CREATE ROLE IF NOT EXISTS openflow_admin;
GRANT CREATE OPENFLOW DEPLOYMENT ON ACCOUNT TO ROLE openflow_admin;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE openflow_admin;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE openflow_admin;

-- Home for the runtime, connector and secret, kept separate from AQ_LAKEHOUSE
CREATE DATABASE IF NOT EXISTS AQ_OPENFLOW;
CREATE SCHEMA IF NOT EXISTS AQ_OPENFLOW.CONTROL;
GRANT USAGE ON DATABASE AQ_OPENFLOW TO ROLE openflow_admin;
GRANT USAGE ON SCHEMA AQ_OPENFLOW.CONTROL TO ROLE openflow_admin;
GRANT CREATE OPENFLOW RUNTIME, CREATE OPENFLOW CONNECTOR, CREATE SECRET
  ON SCHEMA AQ_OPENFLOW.CONTROL TO ROLE openflow_admin;

-- Role the runtime uses to write Bronze
CREATE ROLE IF NOT EXISTS OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;
GRANT ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL TO ROLE openflow_admin;
GRANT USAGE ON DATABASE AQ_OPENFLOW TO ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE ON SCHEMA AQ_OPENFLOW.CONTROL TO ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE, OPERATE ON WAREHOUSE AQ_WH TO ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE, CREATE SCHEMA ON DATABASE AQ_LAKEHOUSE TO ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE ON EXTERNAL VOLUME AQ_ICEBERG_VOL TO ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;

-- Grant the admin role to yourself. Keep secondary roles empty; otherwise
-- ACCOUNTADMIN is sent along and the Openflow login page is blocked.
GRANT ROLE openflow_admin TO USER IDENTIFIER($me);
ALTER USER IDENTIFIER($me) SET DEFAULT_ROLE = openflow_admin DEFAULT_SECONDARY_ROLES = ();

-- Secret holding the openflow_replicator password.
-- Tutorial value (matches ReplicatorPassword used when deploying postgres-ec2.yaml).
-- Outside a test environment, choose a strong password.
USE ROLE openflow_admin;
USE SCHEMA AQ_OPENFLOW.CONTROL;

CREATE OR REPLACE SECRET aq_pg_replicator_password
  TYPE = GENERIC_STRING
  SECRET_STRING = 'replicator123';

-- CREATE OR REPLACE drops existing grants, so grant READ again.
GRANT READ ON SECRET aq_pg_replicator_password TO ROLE OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;