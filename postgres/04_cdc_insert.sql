-- =============================================================================
-- 04_cdc_insert.sql
-- CDC demo, step 1: a new reading arrives.
-- Run after the initial snapshot has finished, then query Bronze to see the new row.
-- =============================================================================
\set ON_ERROR_STOP on

INSERT INTO aq.measurements (
    station_id, measured_at, aqi, dominant_pollutant,
    humidity, pressure, pm25, temperature, wind, source)
VALUES (
    8767, '2021-01-21 20:00:00+07', 110.00, 'pm25',
    84.00, 1009.00, 110.00, 26.00, 3.10, 'waqi_api')
RETURNING measurement_id, station_id, measured_at, aqi, pm25, source;
