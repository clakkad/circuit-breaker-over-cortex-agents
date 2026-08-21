-- ============================================================================
-- Circuit Breaker — Compute Definitions
-- ============================================================================
-- NOTE: Database, schema, and stage are created in pre_deploy.sql (must exist
-- before DCM deploy because procedures reference the stage).
-- ============================================================================

DEFINE WAREHOUSE {{wh_name}}
WITH
    WAREHOUSE_SIZE = '{{wh_size}}'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Circuit Breaker pattern warehouse';
