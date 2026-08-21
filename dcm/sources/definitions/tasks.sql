-- ============================================================================
-- Circuit Breaker — Task Definitions
-- ============================================================================

DEFINE TASK {{db_name}}.{{schema_name}}.{{task_harvest}}
    WAREHOUSE = '{{task_wh}}'
    SCHEDULE = '1 DAY'
    COMMENT = 'Periodic back-fill from agent observability logs'
AS
    CALL {{db_name}}.{{schema_name}}.{{proc_harvest}}();
