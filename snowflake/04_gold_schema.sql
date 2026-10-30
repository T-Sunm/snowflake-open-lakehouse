-- =============================================================================
-- snowflake/04_gold_schema.sql
-- Gold tables on Iceberg. Run once; safe to re-run (IF NOT EXISTS never drops data).
-- The tables are filled by wap/04_load_gold.sql.
--
-- Five aggregates, all built from trusted Silver:
--   AQI_DAILY_SUMMARY     one row per city per day
--   AQI_CITY_RANKING      one row per city per month, with ranks
--   STATION_SUMMARY       one row per station per month, with rank inside the city
--   AQI_HOURLY_PATTERN    one row per city per hour of day
--   AQI_SEASONAL_SUMMARY  one row per city per season
--
-- Column notes:
--   * city_slug, station_id and full_date use the same names as Silver
--   * AQI_CITY_RANKING: record_count is the number of readings, days_observed the
--     number of days with data
--   * AQI_SEASONAL_SUMMARY: one row per season_year and season; first_date /
--     last_date show how much of the season the data covers
--
-- Iceberg tables take EXTERNAL_VOLUME and ICEBERG_VERSION from the database
-- defaults set in 02_database.sql.
-- =============================================================================

USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
USE DATABASE AQ_LAKEHOUSE;
USE SCHEMA AQ_LAKEHOUSE.GOLD;

CREATE ICEBERG TABLE IF NOT EXISTS GOLD.AQI_DAILY_SUMMARY (
    city_slug           STRING,
    city_name           STRING,
    region              STRING,
    full_date           DATE,
    avg_aqi             DOUBLE,
    max_aqi             DOUBLE,
    min_aqi             DOUBLE,
    avg_pm25            DOUBLE,
    avg_pm10            DOUBLE,
    avg_humidity        DOUBLE,
    avg_temperature     DOUBLE,
    station_count       NUMBER(38,0),
    record_count        NUMBER(38,0),
    dominant_pollutant  STRING,
    pollution_level     STRING,
    aggregated_at       TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'gold/aqi_daily_summary';

CREATE ICEBERG TABLE IF NOT EXISTS GOLD.AQI_CITY_RANKING (
    city_slug           STRING,
    city_name           STRING,
    region              STRING,
    year                NUMBER(38,0),
    month               NUMBER(38,0),
    avg_aqi             DOUBLE,
    max_aqi             DOUBLE,
    min_aqi             DOUBLE,
    avg_pm25            DOUBLE,
    avg_pm10            DOUBLE,
    record_count        NUMBER(38,0),
    days_observed       NUMBER(38,0),
    days_good           NUMBER(38,0),
    days_moderate       NUMBER(38,0),
    days_sensitive      NUMBER(38,0),
    days_unhealthy      NUMBER(38,0),
    days_very_unhealthy NUMBER(38,0),
    days_hazardous      NUMBER(38,0),
    dominant_pollutant  STRING,
    pollution_level     STRING,
    aqi_rank            NUMBER(38,0),
    pm25_rank           NUMBER(38,0),
    aggregated_at       TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'gold/aqi_city_ranking';

CREATE ICEBERG TABLE IF NOT EXISTS GOLD.STATION_SUMMARY (
    station_id          NUMBER(38,0),
    station_name        STRING,
    city_slug           STRING,
    city_name           STRING,
    region              STRING,
    latitude            DOUBLE,
    longitude           DOUBLE,
    year                NUMBER(38,0),
    month               NUMBER(38,0),
    avg_aqi             DOUBLE,
    max_aqi             DOUBLE,
    min_aqi             DOUBLE,
    avg_pm25            DOUBLE,
    avg_pm10            DOUBLE,
    avg_humidity        DOUBLE,
    avg_temperature     DOUBLE,
    record_count        NUMBER(38,0),
    dominant_pollutant  STRING,
    pollution_level     STRING,
    rank_in_city        NUMBER(38,0),
    aggregated_at       TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'gold/station_summary';

CREATE ICEBERG TABLE IF NOT EXISTS GOLD.AQI_HOURLY_PATTERN (
    city_slug           STRING,
    city_name           STRING,
    region              STRING,
    hour                NUMBER(38,0),
    time_of_day         STRING,
    avg_aqi             DOUBLE,
    avg_pm25            DOUBLE,
    avg_pm10            DOUBLE,
    record_count        NUMBER(38,0),
    aggregated_at       TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'gold/aqi_hourly_pattern';

CREATE ICEBERG TABLE IF NOT EXISTS GOLD.AQI_SEASONAL_SUMMARY (
    city_slug           STRING,
    city_name           STRING,
    region              STRING,
    season_year         NUMBER(38,0),
    season              STRING,
    first_date          DATE,
    last_date           DATE,
    avg_aqi             DOUBLE,
    max_aqi             DOUBLE,
    min_aqi             DOUBLE,
    avg_pm25            DOUBLE,
    avg_pm10            DOUBLE,
    record_count        NUMBER(38,0),
    dominant_pollutant  STRING,
    aggregated_at       TIMESTAMP_NTZ(6)
)
CATALOG = 'SNOWFLAKE'
BASE_LOCATION = 'gold/aqi_seasonal_summary';

-- Check: five Iceberg tables in the GOLD schema, all empty for now.
SHOW ICEBERG TABLES IN SCHEMA AQ_LAKEHOUSE.GOLD;