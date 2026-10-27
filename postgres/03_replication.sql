-- =============================================================================
-- 03_replication.sql
-- Prepare PostgreSQL for the Openflow Connector for PostgreSQL:
-- logical replication check, a dedicated connector user, and a publication.
--
-- Prerequisite: wal_level = logical (needs a restart).
--   Self-managed:          ALTER SYSTEM SET wal_level = logical;  then restart
--   Amazon RDS / Aurora:   rds.logical_replication = 1 in the parameter group, then reboot
--
-- Usage: psql "<admin connection>" -v replicator_password='<secret>' -f postgres/03_replication.sql
-- =============================================================================
\set ON_ERROR_STOP on

-- 1) Logical replication must be on --------------------------------------------
DO $$
BEGIN
    IF current_setting('wal_level') <> 'logical' THEN
        RAISE EXCEPTION 'wal_level is "%", it must be "logical" (see the header of this file).',
            current_setting('wal_level');
    END IF;
END $$;

-- The connector needs at least 1 replication slot and 2 WAL senders.
SELECT name, setting
FROM pg_settings
WHERE name IN ('wal_level', 'max_replication_slots', 'max_wal_senders')
ORDER BY name;

-- 2) Connector user ------------------------------------------------------------
-- Self-managed PostgreSQL: the REPLICATION attribute.
CREATE ROLE openflow_replicator WITH LOGIN REPLICATION PASSWORD :'replicator_password';
-- Amazon RDS / Aurora: create the role WITHOUT "REPLICATION" above, then instead run:
--   GRANT rds_replication TO openflow_replicator;

GRANT USAGE ON SCHEMA aq TO openflow_replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA aq TO openflow_replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA aq GRANT SELECT ON TABLES TO openflow_replicator;

-- 3) Publication: the tables the connector is allowed to replicate -------------
CREATE PUBLICATION openflow_aq_pub FOR TABLE aq.stations, aq.measurements;

-- 4) Checks --------------------------------------------------------------------
\echo '== Tables in the publication'
SELECT schemaname, tablename FROM pg_publication_tables
WHERE pubname = 'openflow_aq_pub' ORDER BY tablename;

-- Replica identity "d" (default) uses the primary key, which is what UPDATE/DELETE need.
\echo '== Replica identity (d = primary key)'
SELECT c.relname AS table_name, c.relreplident AS replica_identity,
       EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary) AS has_primary_key
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'aq' AND c.relkind = 'r'
ORDER BY c.relname;
