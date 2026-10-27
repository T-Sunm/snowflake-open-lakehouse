-- =============================================================================
-- 05_cdc_update.sql
-- CDC demo, step 2: a reading is corrected after sensor recalibration.
-- Query Bronze afterwards: the same row now carries the new values.
-- If no row is returned, that reading is not in your data:
-- pick another station_id / measured_at from aq.measurements.
-- =============================================================================
\set ON_ERROR_STOP on

UPDATE aq.measurements
SET aqi  = 275.00,
    pm25 = 275.00
WHERE station_id = 8641
  AND measured_at = '2021-01-21 20:00:00+07'
RETURNING measurement_id, station_id, measured_at, aqi, pm25;
