-- =============================================================================
-- 02_load_kaggle.sql
-- Load the historical Kaggle export (historical_air_quality_2021_en.csv)
-- into the operational tables, with source = 'kaggle_2021'.
-- Run BEFORE the Openflow connector starts, so the data arrives in Bronze
-- through the initial snapshot.
--
-- Usage (inside the PostgreSQL container):
--   psql -U postgres -d airquality \
--        -v csv_path=/workspace/postgres/data/historical_air_quality_2021_en.csv \
--        -f /workspace/postgres/02_load_kaggle.sql
--
-- Only format problems from the spreadsheet export are fixed here:
--   '-', '' and '#NAME?'  -> NULL
--   '1,009.00'            -> 1009.00
--   '10.78,106.70'        -> latitude, longitude
--   date + offset         -> timestamptz
--   Status, Alert level   -> not loaded (they only contain '#NAME?')
-- Values themselves are kept as they are; business rules belong in Silver.
-- Safe to re-run: stations are updated, readings already present are skipped.
-- =============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE raw_aqi (
    station_id          text,
    aqi                 text,
    location            text,
    station_name        text,
    url                 text,
    dominant_pollutant  text,
    co                  text,
    dew                 text,
    humidity            text,
    no2                 text,
    o3                  text,
    pressure            text,
    pm10                text,
    pm25                text,
    so2                 text,
    temperature         text,
    wind                text,
    data_time           text,
    data_tz             text,
    status              text,
    alert_level         text
) ON COMMIT DROP;

-- \copy does not expand psql variables in its arguments, so build the command first.
\set copy_cmd '\\copy raw_aqi FROM ' :'csv_path' ' WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')'
:copy_cmd

-- Text -> numeric, treating placeholders as missing.
CREATE FUNCTION pg_temp.to_num(v text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN v IS NULL OR btrim(v) IN ('', '-', '#NAME?') THEN NULL
        WHEN replace(btrim(v), ',', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
            THEN replace(btrim(v), ',', '')::numeric
        ELSE NULL
    END
$$;

CREATE TEMP VIEW clean_aqi AS
SELECT
    station_id::integer                             AS station_id,
    station_name,
    pg_temp.to_num(split_part(location, ',', 1))    AS latitude,
    pg_temp.to_num(split_part(location, ',', 2))    AS longitude,
    url,
    -- The file mixes two formats: '2021-01-21 19:00:00' + '+07:00' in the next column,
    -- and '2021-07-31T08:00:00+07:00' with the offset already included.
    CASE
        WHEN btrim(data_time) ~ '([+-][0-9]{2}:?[0-9]{2}|Z)$' THEN btrim(data_time)::timestamptz
        ELSE (btrim(data_time) || COALESCE(NULLIF(btrim(data_tz), ''), '+07:00'))::timestamptz
    END                                             AS measured_at,
    pg_temp.to_num(aqi)                             AS aqi,
    NULLIF(lower(btrim(dominant_pollutant)), '')    AS dominant_pollutant,
    pg_temp.to_num(co)          AS co,
    pg_temp.to_num(dew)         AS dew,
    pg_temp.to_num(humidity)    AS humidity,
    pg_temp.to_num(no2)         AS no2,
    pg_temp.to_num(o3)          AS o3,
    pg_temp.to_num(pressure)    AS pressure,
    pg_temp.to_num(pm10)        AS pm10,
    pg_temp.to_num(pm25)        AS pm25,
    pg_temp.to_num(so2)         AS so2,
    pg_temp.to_num(temperature) AS temperature,
    pg_temp.to_num(wind)        AS wind
FROM raw_aqi
WHERE NULLIF(btrim(station_id), '') IS NOT NULL
  AND NULLIF(btrim(data_time), '') IS NOT NULL;

-- 1) Stations: one row per station, attributes from its latest reading.
INSERT INTO aq.stations (station_id, station_name, latitude, longitude, url)
SELECT DISTINCT ON (station_id)
       station_id, station_name, latitude, longitude, url
FROM clean_aqi
ORDER BY station_id, measured_at DESC
ON CONFLICT (station_id) DO UPDATE
SET station_name = EXCLUDED.station_name,
    latitude     = EXCLUDED.latitude,
    longitude    = EXCLUDED.longitude,
    url          = EXCLUDED.url;

-- 2) Measurements: one row per station and time; duplicates are skipped.
INSERT INTO aq.measurements (
    station_id, measured_at, aqi, dominant_pollutant,
    co, dew, humidity, no2, o3, pressure, pm10, pm25, so2, temperature, wind, source)
SELECT DISTINCT ON (station_id, measured_at)
       station_id, measured_at, aqi, dominant_pollutant,
       co, dew, humidity, no2, o3, pressure, pm10, pm25, so2, temperature, wind,
       'kaggle_2021'
FROM clean_aqi
ORDER BY station_id, measured_at
ON CONFLICT (station_id, measured_at) DO NOTHING;

\echo
\echo '== Rows in the file vs. rows in the tables'
SELECT (SELECT count(*) FROM raw_aqi)         AS csv_rows,
       (SELECT count(*) FROM raw_aqi
         WHERE NULLIF(btrim(station_id), '') IS NULL
            OR NULLIF(btrim(data_time), '') IS NULL) AS skipped_no_id_or_time,
       (SELECT count(*) FROM aq.stations)     AS stations,
       (SELECT count(*) FROM aq.measurements) AS measurements;

COMMIT;
