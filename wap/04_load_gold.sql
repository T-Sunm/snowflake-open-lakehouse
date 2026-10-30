-- =============================================================================
-- wap/04_load_gold.sql       GOLD step: aggregates built from trusted Silver
--
-- Runs after Publish. Each table is rebuilt in ONE statement (INSERT OVERWRITE),
-- so a reader sees either the old aggregate or the new one, never a half-built
-- table. The Gold tables keep their name and place on S3.
--
-- Rules:
--   * ranks are computed per month (PARTITION BY year, month)
--   * a NULL average gets NO rank and sorts last, so a city with no AQI at all
--     (Nha Trang here) is not ranked as the most polluted
--   * AQI_CITY_RANKING.record_count counts readings; days_observed counts days
--   * the seasonal table is grouped by season_year
--   * a NULL AQI has no pollution level
--
-- The monthly city ranking averages the DAILY averages, so every day weighs the
-- same however many stations reported.
-- =============================================================================

USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
USE DATABASE AQ_LAKEHOUSE;
USE SCHEMA AQ_LAKEHOUSE.GOLD;

-- -----------------------------------------------------------------------------
-- 1. Daily summary
-- -----------------------------------------------------------------------------
INSERT OVERWRITE INTO GOLD.AQI_DAILY_SUMMARY (
    city_slug, city_name, region, full_date, avg_aqi, max_aqi, min_aqi,
    avg_pm25, avg_pm10, avg_humidity, avg_temperature, station_count,
    record_count, dominant_pollutant, pollution_level, aggregated_at
)
SELECT
    c.city_slug,
    c.city_name,
    c.region,
    d.full_date,
    AVG(f.aqi),
    MAX(f.aqi),
    MIN(f.aqi),
    AVG(f.pm25),
    AVG(f.pm10),
    AVG(f.humidity),
    AVG(f.temperature),
    COUNT(DISTINCT f.station_key),
    COUNT(*),
    MODE(f.dominant_pollutant),
    SILVER.AQI_CATEGORY(MAX(f.aqi)),
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SILVER.FACT_AQI f
JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
JOIN SILVER.DIM_DATE d ON d.date_key = f.date_key
GROUP BY c.city_slug, c.city_name, c.region, d.full_date;

-- -----------------------------------------------------------------------------
-- 2. City ranking per month
-- -----------------------------------------------------------------------------
INSERT OVERWRITE INTO GOLD.AQI_CITY_RANKING (
    city_slug, city_name, region, year, month, avg_aqi, max_aqi, min_aqi,
    avg_pm25, avg_pm10, record_count, days_observed, days_good, days_moderate,
    days_sensitive, days_unhealthy, days_very_unhealthy, days_hazardous,
    dominant_pollutant, pollution_level, aqi_rank, pm25_rank, aggregated_at
)
WITH daily AS (
    SELECT
        c.city_slug, c.city_name, c.region,
        d.year AS year, d.month AS month, d.full_date AS full_date,
        AVG(f.aqi)  AS avg_aqi,
        MAX(f.aqi)  AS max_aqi,
        MIN(f.aqi)  AS min_aqi,
        AVG(f.pm25) AS avg_pm25,
        AVG(f.pm10) AS avg_pm10,
        COUNT(*)    AS record_count,
        MODE(f.dominant_pollutant)      AS dominant_pollutant,
        SILVER.AQI_CATEGORY(MAX(f.aqi)) AS pollution_level
    FROM SILVER.FACT_AQI f
    JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
    JOIN SILVER.DIM_DATE d ON d.date_key = f.date_key
    GROUP BY c.city_slug, c.city_name, c.region, d.year, d.month, d.full_date
),
monthly AS (
    SELECT
        city_slug, city_name, region, year, month,
        AVG(avg_aqi)       AS avg_aqi,
        MAX(max_aqi)       AS max_aqi,
        MIN(min_aqi)       AS min_aqi,
        AVG(avg_pm25)      AS avg_pm25,
        AVG(avg_pm10)      AS avg_pm10,
        SUM(record_count)  AS record_count,
        COUNT(*)           AS days_observed,
        COUNT_IF(pollution_level = 'Good')                           AS days_good,
        COUNT_IF(pollution_level = 'Moderate')                       AS days_moderate,
        COUNT_IF(pollution_level = 'Unhealthy for Sensitive Groups') AS days_sensitive,
        COUNT_IF(pollution_level = 'Unhealthy')                      AS days_unhealthy,
        COUNT_IF(pollution_level = 'Very Unhealthy')                 AS days_very_unhealthy,
        COUNT_IF(pollution_level = 'Hazardous')                      AS days_hazardous,
        MODE(dominant_pollutant)                                     AS dominant_pollutant,
        SILVER.AQI_CATEGORY(AVG(avg_aqi))                            AS pollution_level
    FROM daily
    GROUP BY city_slug, city_name, region, year, month
)
SELECT
    city_slug, city_name, region, year, month, avg_aqi, max_aqi, min_aqi,
    avg_pm25, avg_pm10, record_count, days_observed, days_good, days_moderate,
    days_sensitive, days_unhealthy, days_very_unhealthy, days_hazardous,
    dominant_pollutant, pollution_level,
    IFF(avg_aqi IS NULL, NULL,
        DENSE_RANK() OVER (PARTITION BY year, month ORDER BY avg_aqi DESC NULLS LAST)),
    IFF(avg_pm25 IS NULL, NULL,
        DENSE_RANK() OVER (PARTITION BY year, month ORDER BY avg_pm25 DESC NULLS LAST)),
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM monthly;

-- -----------------------------------------------------------------------------
-- 3. Station summary per month, with rank inside the city
-- -----------------------------------------------------------------------------
INSERT OVERWRITE INTO GOLD.STATION_SUMMARY (
    station_id, station_name, city_slug, city_name, region, latitude, longitude,
    year, month, avg_aqi, max_aqi, min_aqi, avg_pm25, avg_pm10, avg_humidity,
    avg_temperature, record_count, dominant_pollutant, pollution_level,
    rank_in_city, aggregated_at
)
WITH station AS (
    SELECT
        st.station_id, st.station_name,
        c.city_slug, c.city_name, c.region,
        st.latitude, st.longitude,
        d.year AS year, d.month AS month,
        AVG(f.aqi)         AS avg_aqi,
        MAX(f.aqi)         AS max_aqi,
        MIN(f.aqi)         AS min_aqi,
        AVG(f.pm25)        AS avg_pm25,
        AVG(f.pm10)        AS avg_pm10,
        AVG(f.humidity)    AS avg_humidity,
        AVG(f.temperature) AS avg_temperature,
        COUNT(*)           AS record_count,
        MODE(f.dominant_pollutant) AS dominant_pollutant
    FROM SILVER.FACT_AQI f
    JOIN SILVER.DIM_STATION st ON st.station_key = f.station_key
    JOIN SILVER.DIM_CITY c     ON c.city_key     = f.city_key
    JOIN SILVER.DIM_DATE d     ON d.date_key     = f.date_key
    GROUP BY st.station_id, st.station_name, c.city_slug, c.city_name, c.region,
             st.latitude, st.longitude, d.year, d.month
)
SELECT
    station_id, station_name, city_slug, city_name, region, latitude, longitude,
    year, month, avg_aqi, max_aqi, min_aqi, avg_pm25, avg_pm10, avg_humidity,
    avg_temperature, record_count, dominant_pollutant,
    SILVER.AQI_CATEGORY(avg_aqi),
    IFF(avg_aqi IS NULL, NULL,
        DENSE_RANK() OVER (PARTITION BY city_slug, year, month ORDER BY avg_aqi DESC NULLS LAST)),
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM station;

-- -----------------------------------------------------------------------------
-- 4. Hour-of-day pattern
-- -----------------------------------------------------------------------------
INSERT OVERWRITE INTO GOLD.AQI_HOURLY_PATTERN (
    city_slug, city_name, region, hour, time_of_day, avg_aqi, avg_pm25,
    avg_pm10, record_count, aggregated_at
)
SELECT
    c.city_slug,
    c.city_name,
    c.region,
    t.hour,
    t.time_of_day,
    AVG(f.aqi),
    AVG(f.pm25),
    AVG(f.pm10),
    COUNT(*),
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SILVER.FACT_AQI f
JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
JOIN SILVER.DIM_TIME t ON t.time_key = f.time_key
GROUP BY c.city_slug, c.city_name, c.region, t.hour, t.time_of_day;

-- -----------------------------------------------------------------------------
-- 5. Seasonal summary (season_year = the year the season STARTS)
-- -----------------------------------------------------------------------------
INSERT OVERWRITE INTO GOLD.AQI_SEASONAL_SUMMARY (
    city_slug, city_name, region, season_year, season, first_date, last_date,
    avg_aqi, max_aqi, min_aqi, avg_pm25, avg_pm10, record_count,
    dominant_pollutant, aggregated_at
)
SELECT
    c.city_slug,
    c.city_name,
    c.region,
    d.season_year,
    d.season,
    MIN(d.full_date),
    MAX(d.full_date),
    AVG(f.aqi),
    MAX(f.aqi),
    MIN(f.aqi),
    AVG(f.pm25),
    AVG(f.pm10),
    COUNT(*),
    MODE(f.dominant_pollutant),
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SILVER.FACT_AQI f
JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
JOIN SILVER.DIM_DATE d ON d.date_key = f.date_key
GROUP BY c.city_slug, c.city_name, c.region, d.season_year, d.season;

-- =============================================================================
-- CHECKS for running this file by hand. Run each on its own: select it, then
-- Ctrl + Enter.
-- =============================================================================

-- A. Every aggregate accounts for every Silver reading. Expected: six numbers, all 2117.
SELECT
    (SELECT COUNT(*)          FROM SILVER.FACT_AQI)                  AS silver_rows,
    (SELECT SUM(record_count) FROM GOLD.AQI_DAILY_SUMMARY)           AS daily,
    (SELECT SUM(record_count) FROM GOLD.AQI_CITY_RANKING)            AS city_ranking,
    (SELECT SUM(record_count) FROM GOLD.STATION_SUMMARY)             AS station_summary,
    (SELECT SUM(record_count) FROM GOLD.AQI_HOURLY_PATTERN)          AS hourly,
    (SELECT SUM(record_count) FROM GOLD.AQI_SEASONAL_SUMMARY)        AS seasonal;

-- B. Each month ranks its cities from 1. Cities with no AQI (Nha Trang) have no rank.
--    Expected: rank 1 present in every month, Nha Trang's aqi_rank empty.
SELECT year, month, city_name, ROUND(avg_aqi, 1) AS avg_aqi, aqi_rank, days_observed
FROM GOLD.AQI_CITY_RANKING
WHERE year = 2021 AND month = 1
ORDER BY aqi_rank NULLS LAST, city_name;

-- C. Seasons stay whole across the new year, and show how much of each season
--    the data covers. Expected for Ha Noi: dry 2020 (Jan-Apr 2021), rainy 2021,
--    dry 2021 (Nov 2021 only).
SELECT season_year, season, first_date, last_date, record_count, ROUND(avg_aqi, 1) AS avg_aqi
FROM GOLD.AQI_SEASONAL_SUMMARY
WHERE city_slug = 'ha-noi'
ORDER BY season_year, season;

-- D. Hour-of-day pattern for Ha Noi.
SELECT hour, time_of_day, record_count, ROUND(avg_aqi, 1) AS avg_aqi
FROM GOLD.AQI_HOURLY_PATTERN
WHERE city_slug = 'ha-noi'
ORDER BY hour;