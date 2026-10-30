-- =============================================================================
-- wap/01_write_candidate.sql      WRITE step of Write-Audit-Publish
--
-- Builds "Silver Candidate": a copy of Current Silver with the latest Bronze
-- state merged in. Nothing here touches Current Silver, so if the Audit step
-- fails you simply throw the candidate away and Silver is exactly as before.
--
--   Current Silver --clone--> Candidate --MERGE with Bronze--> Candidate (updated)
--
-- The first run is not special: Current Silver is empty, the clone is empty,
-- and the MERGE inserts every live Bronze row.
--
-- What changes between runs is handled by one MERGE per table:
--   * new row in Bronze           -> INSERT
--   * changed row in Bronze       -> UPDATE   (its _SNOWFLAKE_UPDATED_AT moved)
--   * soft-deleted row in Bronze  -> DELETE   (_SNOWFLAKE_DELETED = TRUE)
--
-- Only FACT_AQI and DIM_STATION are cloned because they are the tables that
-- follow Bronze. DIM_DATE, DIM_TIME and DIM_CITY are calendar/reference data
-- and are read straight from SILVER.
--
-- Safe to re-run: the candidate is rebuilt from scratch every time.
-- =============================================================================

USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
USE DATABASE AQ_LAKEHOUSE;

CREATE SCHEMA IF NOT EXISTS SILVER_CANDIDATE;
USE SCHEMA AQ_LAKEHOUSE.SILVER_CANDIDATE;

-- -----------------------------------------------------------------------------
-- 1. Clone Current Silver (no data is copied; the clone shares storage)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE SILVER_CANDIDATE.DIM_STATION CLONE SILVER.DIM_STATION;
CREATE OR REPLACE ICEBERG TABLE SILVER_CANDIDATE.FACT_AQI    CLONE SILVER.FACT_AQI;

-- -----------------------------------------------------------------------------
-- 2. DIM_STATION: one row per station, city taken from the station URL.
--    Stations are never deleted from the dimension (Type 1: latest values win),
--    because fact rows may still point at them.
-- -----------------------------------------------------------------------------
MERGE INTO SILVER_CANDIDATE.DIM_STATION AS t
USING (
    SELECT
        s.STATION_ID        AS station_id,
        c.city_key          AS city_key,
        s.STATION_NAME      AS station_name,
        s.LATITUDE::DOUBLE  AS latitude,
        s.LONGITUDE::DOUBLE AS longitude,
        s.URL               AS url
    FROM AQ.STATIONS s
    LEFT JOIN CONTROL.STATION_CITY_OVERRIDE o ON o.station_id = s.STATION_ID
    LEFT JOIN CONTROL.CITY_MAP m
           ON m.source_city = REGEXP_SUBSTR(s.URL, '/city/vietnam/([^/]+)', 1, 1, 'e', 1)
    JOIN SILVER.DIM_CITY c ON c.city_slug = COALESCE(o.city_slug, m.conformed_city)
    WHERE NOT s._SNOWFLAKE_DELETED
) AS src
ON t.station_id = src.station_id
WHEN MATCHED AND (
        NOT EQUAL_NULL(t.city_key,     src.city_key)
     OR NOT EQUAL_NULL(t.station_name, src.station_name)
     OR NOT EQUAL_NULL(t.latitude,     src.latitude)
     OR NOT EQUAL_NULL(t.longitude,    src.longitude)
     OR NOT EQUAL_NULL(t.url,          src.url)
) THEN UPDATE SET
    city_key     = src.city_key,
    station_name = src.station_name,
    latitude     = src.latitude,
    longitude    = src.longitude,
    url          = src.url,
    loaded_at    = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
WHEN NOT MATCHED THEN INSERT
    (station_key, station_id, city_key, station_name, latitude, longitude, url, loaded_at)
VALUES
    (SILVER.SEQ_STATION_KEY.NEXTVAL, src.station_id, src.city_key, src.station_name,
     src.latitude, src.longitude, src.url, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

-- -----------------------------------------------------------------------------
-- 3. FACT_AQI: one row per measurement.
--    * measured_at is converted to Vietnam time (UTC+7) before date/time keys
--      are derived, otherwise readings after 17:00 land on the next day.
--    * the time key uses the HOUR only (DIM_TIME has one row per hour).
--    * rows that cannot be joined to every dimension are not loaded here;
--      the Audit step catches them by comparing row counts with Bronze.
-- -----------------------------------------------------------------------------
MERGE INTO SILVER_CANDIDATE.FACT_AQI AS t
USING (
    SELECT
        m.MEASUREMENT_ID                                                   AS measurement_id,
        d.date_key                                                         AS date_key,
        tm.time_key                                                        AS time_key,
        st.city_key                                                        AS city_key,
        st.station_key                                                     AS station_key,
        CONVERT_TIMEZONE('Asia/Ho_Chi_Minh', m.MEASURED_AT)::TIMESTAMP_NTZ AS measured_at,
        m.AQI::DOUBLE                                                      AS aqi,
        SILVER.AQI_CATEGORY(m.AQI::DOUBLE)                                 AS pollution_level,
        IFF(TRIM(m.DOMINANT_POLLUTANT) IN ('', '-', 'aqi'),
            NULL, TRIM(m.DOMINANT_POLLUTANT))                              AS dominant_pollutant,
        m.PM25::DOUBLE        AS pm25,
        m.PM10::DOUBLE        AS pm10,
        m.CO::DOUBLE          AS co,
        m.NO2::DOUBLE         AS no2,
        m.O3::DOUBLE          AS o3,
        m.SO2::DOUBLE         AS so2,
        m.HUMIDITY::DOUBLE    AS humidity,
        m.TEMPERATURE::DOUBLE AS temperature,
        m.PRESSURE::DOUBLE    AS pressure,
        m.WIND::DOUBLE        AS wind,
        DECODE(m.SOURCE, 'kaggle_2021', 'kaggle', 'waqi_api', 'api', m.SOURCE) AS source,
        m._SNOWFLAKE_UPDATED_AT                                            AS ingested_at,
        m._SNOWFLAKE_DELETED                                               AS is_deleted
    FROM AQ.MEASUREMENTS m
    JOIN SILVER_CANDIDATE.DIM_STATION st ON st.station_id = m.STATION_ID
    JOIN SILVER.DIM_DATE d  ON d.full_date = CONVERT_TIMEZONE('Asia/Ho_Chi_Minh', m.MEASURED_AT)::DATE
    JOIN SILVER.DIM_TIME tm ON tm.hour     = HOUR(CONVERT_TIMEZONE('Asia/Ho_Chi_Minh', m.MEASURED_AT))
) AS s
ON t.measurement_id = s.measurement_id
WHEN MATCHED AND s.is_deleted THEN DELETE
WHEN MATCHED AND NOT s.is_deleted AND t.ingested_at <> s.ingested_at THEN UPDATE SET
    date_key           = s.date_key,
    time_key           = s.time_key,
    city_key           = s.city_key,
    station_key        = s.station_key,
    measured_at        = s.measured_at,
    aqi                = s.aqi,
    pollution_level    = s.pollution_level,
    dominant_pollutant = s.dominant_pollutant,
    pm25 = s.pm25, pm10 = s.pm10, co = s.co, no2 = s.no2, o3 = s.o3, so2 = s.so2,
    humidity = s.humidity, temperature = s.temperature,
    pressure = s.pressure, wind = s.wind,
    source             = s.source,
    ingested_at        = s.ingested_at
WHEN NOT MATCHED AND NOT s.is_deleted THEN INSERT (
    measurement_id, date_key, time_key, city_key, station_key, measured_at,
    aqi, pollution_level, dominant_pollutant, pm25, pm10, co, no2, o3, so2,
    humidity, temperature, pressure, wind, source, ingested_at
) VALUES (
    s.measurement_id, s.date_key, s.time_key, s.city_key, s.station_key, s.measured_at,
    s.aqi, s.pollution_level, s.dominant_pollutant, s.pm25, s.pm10, s.co, s.no2, s.o3, s.so2,
    s.humidity, s.temperature, s.pressure, s.wind, s.source, s.ingested_at
);

-- =============================================================================
-- CHECKS for running this file by hand. (The Audit step repeats the important
-- ones automatically.) Run each on its own: select it, then Ctrl + Enter.
-- =============================================================================

-- A. Nothing lost: live Bronze rows must equal candidate rows. Expected: 2117 and 2117.
SELECT
    (SELECT COUNT(*) FROM AQ.MEASUREMENTS WHERE NOT _SNOWFLAKE_DELETED) AS bronze_live_rows,
    (SELECT COUNT(*) FROM SILVER_CANDIDATE.FACT_AQI)                    AS candidate_rows;

-- B. Current Silver must be untouched by the write. Expected on the very first
--    run: 0 (it only fills up after the Publish step).
SELECT COUNT(*) AS current_silver_fact_rows FROM SILVER.FACT_AQI;

-- C. The three CDC rows. Expected: 2 rows.
--      320  aqi 275   (the update)
--      2118 present   (the insert)
--    and measurement 434 (the soft delete) must NOT appear.
SELECT measurement_id, aqi, pm25
FROM SILVER_CANDIDATE.FACT_AQI
WHERE measurement_id IN (320, 434, 2118)
ORDER BY measurement_id;

-- D. Stations and cities. Expected: 23 stations, 11 cities, 2117 rows in total.
SELECT c.city_slug, COUNT(DISTINCT f.station_key) AS stations, COUNT(*) AS fact_rows
FROM SILVER_CANDIDATE.FACT_AQI f
JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
GROUP BY c.city_slug
ORDER BY fact_rows DESC;

-- E. Values of dominant_pollutant after cleaning. Expected: pm25 1332, NULL 541, pm10 244
--    (blank, '-' and 'aqi' are turned into NULL).
SELECT dominant_pollutant, COUNT(*) AS n
FROM SILVER_CANDIDATE.FACT_AQI
GROUP BY dominant_pollutant
ORDER BY n DESC;