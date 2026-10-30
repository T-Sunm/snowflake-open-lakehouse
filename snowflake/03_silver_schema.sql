-- =============================================================================
-- 03_silver_schema.sql
-- Silver star schema on Iceberg + the small control tables it depends on.
--
-- SAFE TO RE-RUN. Every Silver table is created with IF NOT EXISTS and every
-- dimension is filled with MERGE, so running this file again never deletes or
-- duplicates data. (If you really want to change a table's columns, drop that
-- table by hand first, then run this file.)
--
-- Runs as openflow_admin. That role inherits OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL,
-- which already has CREATE SCHEMA on AQ_LAKEHOUSE, USAGE on AQ_ICEBERG_VOL and
-- USAGE on AQ_WH, so no extra grants are needed here.
--
-- Iceberg tables pick up EXTERNAL_VOLUME and ICEBERG_VERSION from the database
-- defaults set in 02_database.sql, so only CATALOG and BASE_LOCATION are given.
--
-- Modelling rules for this dataset:
--   * a station's city comes from its URL (aqicn.org/city/vietnam/<slug>/...)
--   * DIM_STATION is keyed by station_id; the city is an attribute of the station
--   * DIM_DATE has season_year, so a dry season that spans two calendar years
--     stays in one season
--   * FACT_AQI carries measurement_id so Silver can MERGE against Bronze
-- =============================================================================

USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
USE DATABASE AQ_LAKEHOUSE;

CREATE SCHEMA IF NOT EXISTS SILVER;
CREATE SCHEMA IF NOT EXISTS GOLD;
CREATE SCHEMA IF NOT EXISTS CONTROL;

-- -----------------------------------------------------------------------------
-- CONTROL: city conformance.
-- These three are reference data defined by this file, so they are rebuilt on
-- every run (CREATE OR REPLACE + INSERT). Nothing else depends on their history.
-- -----------------------------------------------------------------------------

-- URL slug (aqicn.org/city/vietnam/<slug>/...) -> conformed city slug.
CREATE OR REPLACE TABLE CONTROL.CITY_MAP (
    source_city    STRING NOT NULL,
    conformed_city STRING NOT NULL
);

INSERT INTO CONTROL.CITY_MAP VALUES
    ('hanoi',            'ha-noi'),
    ('ha-noi',           'ha-noi'),
    ('bac-ninh',         'bac-ninh'),
    ('da-nang',          'da-nang'),
    ('nha-trang',        'nha-trang'),
    ('ha-long',          'ha-long'),
    ('quang-ninh',       'quang-ninh'),
    ('ho-chi-minh-city', 'ho-chi-minh-city'),
    ('thua-thien-hue',   'thua-thien-hue'),
    ('gia-lai',          'gia-lai'),
    ('lao-cai',          'lao-cai'),
    ('cao-bang',         'cao-bang');

-- Stations whose URL carries no city slug.
CREATE OR REPLACE TABLE CONTROL.STATION_CITY_OVERRIDE (
    station_id NUMBER(38,0) NOT NULL,
    city_slug  STRING       NOT NULL
);

INSERT INTO CONTROL.STATION_CITY_OVERRIDE VALUES
    (13252, 'cao-bang');   -- URL is http://cem.gov.vn/

CREATE OR REPLACE TABLE CONTROL.CITY_REFERENCE (
    city_slug STRING NOT NULL,
    city_name STRING NOT NULL,
    region    STRING NOT NULL,
    lat       DOUBLE,
    lon       DOUBLE
);

INSERT INTO CONTROL.CITY_REFERENCE VALUES
    ('ha-noi',           'Ha Noi',           'North',             21.0285, 105.8542),
    ('bac-ninh',         'Bac Ninh',         'North',             21.1861, 106.0763),
    ('ha-long',          'Ha Long',          'North',             20.9599, 107.0448),
    ('quang-ninh',       'Quang Ninh',       'North',             21.0064, 107.2925),
    ('lao-cai',          'Lao Cai',          'North',             22.4809, 103.9755),
    ('cao-bang',         'Cao Bang',         'North',             22.6657, 106.2579),
    ('thua-thien-hue',   'Thua Thien Hue',   'Central',           16.4637, 107.5909),
    ('da-nang',          'Da Nang',          'Central',           16.0544, 108.2022),
    ('nha-trang',        'Nha Trang',        'Central',           12.2388, 109.1967),
    ('gia-lai',          'Gia Lai',          'Central Highlands', 13.9718, 108.0151),
    ('ho-chi-minh-city', 'Ho Chi Minh City', 'South',             10.8231, 106.6297);

-- The audit log keeps its history, so it is never replaced.
CREATE TABLE IF NOT EXISTS CONTROL.DQ_RESULTS (
    run_id     STRING,
    layer      STRING,
    check_name STRING,
    severity   STRING,          -- 'fail' blocks publish, 'warn' does not
    passed     BOOLEAN,
    detail     STRING,
    checked_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------------
-- Surrogate-key sequences (used in MERGE ... INSERT values)
-- -----------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS SILVER.SEQ_CITY_KEY    START = 1 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS SILVER.SEQ_STATION_KEY START = 1 INCREMENT = 1;

-- -----------------------------------------------------------------------------
-- AQI category. A NULL AQI has no category.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION SILVER.AQI_CATEGORY(aqi DOUBLE)
RETURNS STRING
AS
$$
CASE
  WHEN aqi IS NULL THEN NULL
  WHEN aqi <= 50   THEN 'Good'
  WHEN aqi <= 100  THEN 'Moderate'
  WHEN aqi <= 150  THEN 'Unhealthy for Sensitive Groups'
  WHEN aqi <= 200  THEN 'Unhealthy'
  WHEN aqi <= 300  THEN 'Very Unhealthy'
  ELSE 'Hazardous'
END
$$;

-- -----------------------------------------------------------------------------
-- DIM_DATE (smart key YYYYMMDD). Dry season = Nov-Apr, rainy = May-Oct.
-- season_year is the year the season STARTS: Jan-Apr 2021 belongs to the dry
-- season that started in Nov 2020.
-- -----------------------------------------------------------------------------
CREATE ICEBERG TABLE IF NOT EXISTS SILVER.DIM_DATE (
    date_key      NUMBER(8,0) NOT NULL,
    full_date     DATE        NOT NULL,
    year          NUMBER(38,0),
    month         NUMBER(38,0),
    month_name    STRING,
    day_of_month  NUMBER(38,0),
    day_of_week   NUMBER(38,0),
    day_name      STRING,
    quarter       NUMBER(38,0),
    week_of_year  NUMBER(38,0),
    is_weekend    BOOLEAN,
    season        STRING,
    season_year   NUMBER(38,0)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'silver/dim_date';

MERGE INTO SILVER.DIM_DATE AS t
USING (
    SELECT
        TO_NUMBER(TO_VARCHAR(d.value, 'YYYYMMDD')) AS date_key,
        d.value                                    AS full_date,
        YEAR(d.value)                              AS year,
        MONTH(d.value)                             AS month,
        MONTHNAME(d.value)                         AS month_name,
        DAY(d.value)                               AS day_of_month,
        DAYOFWEEKISO(d.value)                      AS day_of_week,
        DAYNAME(d.value)                           AS day_name,
        QUARTER(d.value)                           AS quarter,
        WEEKOFYEAR(d.value)                        AS week_of_year,
        DAYOFWEEKISO(d.value) IN (6, 7)            AS is_weekend,
        IFF(MONTH(d.value) BETWEEN 5 AND 10, 'Rainy', 'Dry') AS season,
        CASE
          WHEN MONTH(d.value) >= 5 THEN YEAR(d.value)
          ELSE YEAR(d.value) - 1
        END                                        AS season_year
    FROM (
        SELECT DATEADD(DAY, seq4(), '2019-01-01'::DATE) AS value
        FROM TABLE(GENERATOR(ROWCOUNT => 4383))      -- 2019-01-01 .. 2030-12-31
    ) d
) AS s
ON t.date_key = s.date_key
WHEN NOT MATCHED THEN INSERT
    (date_key, full_date, year, month, month_name, day_of_month, day_of_week,
     day_name, quarter, week_of_year, is_weekend, season, season_year)
VALUES
    (s.date_key, s.full_date, s.year, s.month, s.month_name, s.day_of_month,
     s.day_of_week, s.day_name, s.quarter, s.week_of_year, s.is_weekend,
     s.season, s.season_year);

-- -----------------------------------------------------------------------------
-- DIM_TIME (smart key HHMM, hour grain)
-- -----------------------------------------------------------------------------
CREATE ICEBERG TABLE IF NOT EXISTS SILVER.DIM_TIME (
    time_key    NUMBER(4,0)  NOT NULL,
    hour        NUMBER(38,0) NOT NULL,
    minute      NUMBER(38,0) NOT NULL,
    time_of_day STRING       NOT NULL
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'silver/dim_time';

MERGE INTO SILVER.DIM_TIME AS t
USING (
    SELECT
        h.value * 100 AS time_key,
        h.value       AS hour,
        0             AS minute,
        CASE
          WHEN h.value BETWEEN 5 AND 11  THEN 'Morning'
          WHEN h.value BETWEEN 12 AND 17 THEN 'Afternoon'
          WHEN h.value BETWEEN 18 AND 22 THEN 'Evening'
          ELSE 'Night'
        END           AS time_of_day
    FROM (SELECT seq4() AS value FROM TABLE(GENERATOR(ROWCOUNT => 24))) h
) AS s
ON t.time_key = s.time_key
WHEN NOT MATCHED THEN INSERT (time_key, hour, minute, time_of_day)
VALUES (s.time_key, s.hour, s.minute, s.time_of_day);

-- -----------------------------------------------------------------------------
-- DIM_CITY
-- -----------------------------------------------------------------------------
CREATE ICEBERG TABLE IF NOT EXISTS SILVER.DIM_CITY (
    city_key  NUMBER(38,0) NOT NULL,
    city_slug STRING       NOT NULL,
    city_name STRING       NOT NULL,
    region    STRING       NOT NULL,
    lat       DOUBLE,
    lon       DOUBLE
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'silver/dim_city';

MERGE INTO SILVER.DIM_CITY AS t
USING CONTROL.CITY_REFERENCE AS s
ON t.city_slug = s.city_slug
WHEN MATCHED THEN UPDATE SET
    city_name = s.city_name, region = s.region, lat = s.lat, lon = s.lon
WHEN NOT MATCHED THEN INSERT (city_key, city_slug, city_name, region, lat, lon)
VALUES (SILVER.SEQ_CITY_KEY.NEXTVAL, s.city_slug, s.city_name, s.region, s.lat, s.lon);

-- -----------------------------------------------------------------------------
-- DIM_STATION and FACT_AQI are created empty here and filled by the
-- Write-Audit-Publish cycle (wap/).
-- Natural key of DIM_STATION is station_id alone (the city is an attribute).
-- measured_at is stored as Vietnam local time (UTC+7) without a zone.
-- -----------------------------------------------------------------------------
CREATE ICEBERG TABLE IF NOT EXISTS SILVER.DIM_STATION (
    station_key  NUMBER(38,0) NOT NULL,
    station_id   NUMBER(38,0) NOT NULL,
    city_key     NUMBER(38,0) NOT NULL,
    station_name STRING       NOT NULL,
    latitude     DOUBLE,
    longitude    DOUBLE,
    url          STRING,
    loaded_at    TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'silver/dim_station';

CREATE ICEBERG TABLE IF NOT EXISTS SILVER.FACT_AQI (
    measurement_id     NUMBER(38,0) NOT NULL,
    date_key           NUMBER(8,0)  NOT NULL,
    time_key           NUMBER(4,0)  NOT NULL,
    city_key           NUMBER(38,0) NOT NULL,
    station_key        NUMBER(38,0) NOT NULL,
    measured_at        TIMESTAMP_NTZ(6) NOT NULL,
    aqi                DOUBLE,
    pollution_level    STRING,
    dominant_pollutant STRING,
    pm25               DOUBLE,
    pm10               DOUBLE,
    co                 DOUBLE,
    no2                DOUBLE,
    o3                 DOUBLE,
    so2                DOUBLE,
    humidity           DOUBLE,
    temperature        DOUBLE,
    pressure           DOUBLE,
    wind               DOUBLE,
    source             STRING       NOT NULL,
    ingested_at        TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'silver/fact_aqi';

-- -----------------------------------------------------------------------------
-- Checks. Run each one on its own (select it, then Ctrl + Enter).
-- -----------------------------------------------------------------------------

-- Expected: dim_date 4383, dim_time 24, dim_city 11 (also after re-running).
SELECT
  (SELECT COUNT(*) FROM SILVER.DIM_DATE) AS dim_date,
  (SELECT COUNT(*) FROM SILVER.DIM_TIME) AS dim_time,
  (SELECT COUNT(*) FROM SILVER.DIM_CITY) AS dim_city;

-- Every live station must resolve to a city. Expected: 0 rows.
SELECT s.STATION_ID, s.URL
FROM AQ_LAKEHOUSE.AQ.STATIONS s
LEFT JOIN CONTROL.STATION_CITY_OVERRIDE o ON o.station_id = s.STATION_ID
LEFT JOIN CONTROL.CITY_MAP m
       ON m.source_city = REGEXP_SUBSTR(s.URL, '/city/vietnam/([^/]+)', 1, 1, 'e', 1)
WHERE NOT s._SNOWFLAKE_DELETED
  AND COALESCE(o.city_slug, m.conformed_city) IS NULL;

-- Stations per city. Expected: ha-noi 11, bac-ninh 3, the other nine cities 1 each (23 total).
SELECT COALESCE(o.city_slug, m.conformed_city) AS city_slug, COUNT(*) AS stations
FROM AQ_LAKEHOUSE.AQ.STATIONS s
LEFT JOIN CONTROL.STATION_CITY_OVERRIDE o ON o.station_id = s.STATION_ID
LEFT JOIN CONTROL.CITY_MAP m
       ON m.source_city = REGEXP_SUBSTR(s.URL, '/city/vietnam/([^/]+)', 1, 1, 'e', 1)
WHERE NOT s._SNOWFLAKE_DELETED
GROUP BY 1
ORDER BY stations DESC, 1;