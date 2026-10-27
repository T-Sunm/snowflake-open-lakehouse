-- =============================================================================
-- 06_cdc_delete.sql
-- CDC demo, step 3: an invalid reading is removed by the operator
-- (dominant pollutant recorded as 'aqi' and no PM2.5 value).
-- Query Bronze afterwards: the row is still there, with _SNOWFLAKE_DELETED = TRUE.
-- If no row is returned, that reading is not in your data:
-- pick another station_id / measured_at from aq.measurements.
-- =============================================================================
\set ON_ERROR_STOP on

DELETE FROM aq.measurements
WHERE station_id = 8688
  AND measured_at = '2021-01-21 20:00:00+07'
RETURNING measurement_id, station_id, measured_at, aqi, dominant_pollutant;
