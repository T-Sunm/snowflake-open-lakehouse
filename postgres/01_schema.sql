-- =============================================================================
-- 01_schema.sql
-- Operational source schema for the air-quality demo.
--
-- Two sources write into the same tables, because the Kaggle export was
-- collected from the same WAQI API and has the same fields:
--   kaggle_2021  historical readings (historical_air_quality_2021_en.csv)
--   waqi_api     new readings from https://api.waqi.info/feed/{city}/
--
-- Every table has a primary key so the Openflow connector can replicate
-- INSERT, UPDATE and DELETE.
--
-- Usage: psql "<connection>" -f postgres/01_schema.sql
-- =============================================================================
\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS aq;

-- One row per monitoring station (WAQI station id = "idx" in the API).
CREATE TABLE IF NOT EXISTS aq.stations (
    station_id    integer PRIMARY KEY,
    station_name  text NOT NULL,
    latitude      numeric(9,6),
    longitude     numeric(9,6),
    url           text
);

-- One row per station per reading time.
CREATE TABLE IF NOT EXISTS aq.measurements (
    measurement_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    station_id          integer NOT NULL REFERENCES aq.stations (station_id),
    measured_at         timestamptz NOT NULL,   -- reading time reported by the station
    aqi                 numeric(6,2),
    dominant_pollutant  text,
    co                  numeric(8,2),
    dew                 numeric(8,2),
    humidity            numeric(8,2),
    no2                 numeric(8,2),
    o3                  numeric(8,2),
    pressure            numeric(8,2),
    pm10                numeric(8,2),
    pm25                numeric(8,2),
    so2                 numeric(8,2),
    temperature         numeric(8,2),
    wind                numeric(8,2),
    source              text NOT NULL CHECK (source IN ('kaggle_2021', 'waqi_api')),
    -- An offline station keeps returning its last reading; this key stops it being stored twice.
    CONSTRAINT uq_measurement_station_time UNIQUE (station_id, measured_at)
);

CREATE INDEX IF NOT EXISTS ix_measurements_measured_at ON aq.measurements (measured_at);
