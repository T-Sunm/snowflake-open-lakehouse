-- =============================================================================
-- wap/03_publish.sql      PUBLISH step of Write-Audit-Publish
--
-- Makes the audited Silver Candidate the new Current Silver.
--
-- ONLY RUN THIS AFTER THE AUDIT PASSED. wap/run.py enforces that for you. If you
-- run this file by hand, run the audit first: nothing in this file checks it.
--
-- How it publishes
--   INSERT OVERWRITE replaces the whole content of a table in ONE statement:
--   readers see either the old content or the new content, never a mix.
--   The table keeps its name, its place on S3 and its grants, so downstream
--   readers (Gold, DuckDB through Horizon) need no change.
--
--   The overwrite rewrites the data files. At this size that takes seconds;
--   on a very large table you would prefer a metadata-only swap, but the
--   Snowflake documentation does not confirm SWAP WITH for Iceberg tables, so
--   this tutorial does not rely on it.
--
-- Order matters: DIM_STATION first, then FACT_AQI. Existing stations keep their
-- station_key (the Write step MERGEs, it does not renumber), so between the two
-- statements the fact table still resolves against the new station dimension.
--
-- The candidate is a clone of Current Silver, so both tables have identical
-- columns and SELECT * is safe here.
--
-- Rollback (Time Travel keeps the previous version for 1 day by default):
--   find the query id of the publish statement in Query History, then
--   INSERT OVERWRITE INTO SILVER.FACT_AQI
--     SELECT * FROM SILVER.FACT_AQI BEFORE (STATEMENT => '<query_id>');
-- =============================================================================

USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
USE DATABASE AQ_LAKEHOUSE;
USE SCHEMA AQ_LAKEHOUSE.SILVER;

INSERT OVERWRITE INTO SILVER.DIM_STATION
SELECT * FROM SILVER_CANDIDATE.DIM_STATION;

INSERT OVERWRITE INTO SILVER.FACT_AQI
SELECT * FROM SILVER_CANDIDATE.FACT_AQI;

-- =============================================================================
-- CHECKS for running this file by hand. Run each on its own: select it, then
-- Ctrl + Enter.
-- =============================================================================

-- A. Current Silver now equals the candidate.
--    Expected on the first publish: 2117 / 2117 and 23 / 23.
SELECT
    (SELECT COUNT(*) FROM SILVER.FACT_AQI)                AS silver_fact_rows,
    (SELECT COUNT(*) FROM SILVER_CANDIDATE.FACT_AQI)      AS candidate_fact_rows,
    (SELECT COUNT(*) FROM SILVER.DIM_STATION)             AS silver_stations,
    (SELECT COUNT(*) FROM SILVER_CANDIDATE.DIM_STATION)   AS candidate_stations;

-- B. The three CDC rows are now in Current Silver. Expected: 2 rows
--    (320 with aqi 275, and 2118). Measurement 434 must be absent.
SELECT measurement_id, aqi, pm25
FROM SILVER.FACT_AQI
WHERE measurement_id IN (320, 434, 2118)
ORDER BY measurement_id;

-- C. Nothing differs between Silver and the candidate. Expected: 0.
SELECT COUNT(*) AS differing_rows
FROM (
    SELECT * FROM SILVER.FACT_AQI
    MINUS
    SELECT * FROM SILVER_CANDIDATE.FACT_AQI
);

-- D. The star schema answers a question end to end.
--    Expected: 11 cities; Ha Noi has the most readings.
SELECT c.city_name, d.season, COUNT(*) AS readings, ROUND(AVG(f.aqi), 1) AS avg_aqi
FROM SILVER.FACT_AQI f
JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
JOIN SILVER.DIM_DATE d ON d.date_key = f.date_key
GROUP BY c.city_name, d.season
ORDER BY readings DESC
LIMIT 10;
