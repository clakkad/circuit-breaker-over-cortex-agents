-- ============================================================================
-- Circuit Breaker — Table Definitions
-- ============================================================================

DEFINE TABLE {{db_name}}.{{schema_name}}.{{table_name}} (
    QUERY_ID              VARCHAR,
    SQL_TEXT              VARCHAR,
    USER_QUERY_NORMALIZED VARCHAR NOT NULL PRIMARY KEY,
    LAST_ASKED_AT         TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    IS_EXPIRED            BOOLEAN DEFAULT FALSE,
    HIT_COUNT             NUMBER DEFAULT 0,
    RECENCY_DAYS          NUMBER DEFAULT 0,
    AGENT_NAME            VARCHAR,
    THREAD_ID             NUMBER,
    LAST_LOG_PULL_AT      TIMESTAMP_LTZ
)
COMMENT = 'Stores unique NL questions (FAQ history), their cached SQL, and metadata for the Circuit Breaker layer.';
