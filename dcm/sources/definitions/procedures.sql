-- ============================================================================
-- Circuit Breaker — Procedure Definitions
-- ============================================================================

DEFINE PROCEDURE {{db_name}}.{{schema_name}}.{{proc_intercept}}(
    P_USER_QUESTION         VARCHAR,
    P_HYBRID_SEARCH_ENABLED BOOLEAN,
    P_CONFIDENCE_THRESHOLD  FLOAT,
    P_RECENCY_WINDOW_DAYS   NUMBER,
    P_EXPIRY_THRESHOLD_DAYS NUMBER,
    P_RESPONSE_MODEL        VARCHAR,
    P_AGENT_NAME            VARCHAR,
    P_PREVIEW_ROWS          NUMBER
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake')
IMPORTS = ('@{{db_name}}.{{schema_name}}.{{stage_name}}/cb_core.py')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
from snowflake.snowpark import Session
import cb_core


def run(session: Session,
        p_user_question: str,
        p_hybrid_search_enabled: bool,
        p_confidence_threshold: float,
        p_recency_window_days: int,
        p_expiry_threshold_days: int,
        p_response_model: str,
        p_agent_name: str,
        p_preview_rows: int) -> dict:
    """Circuit Breaker orchestrator — 2-pronged matching: exact first, then hybrid if enabled."""

    p_normalized_user_question = cb_core.normalize_question(p_user_question)

    # --- PRONG 1: Exact match ---
    match = cb_core.exact_match(session, p_normalized_user_question, p_recency_window_days)

    # --- PRONG 2: Hybrid semantic search (if enabled and no exact match) ---
    if not match and p_hybrid_search_enabled:
        match = cb_core.hybrid_search(session, p_normalized_user_question,
                                      p_recency_window_days,
                                      confidence_threshold=p_confidence_threshold)

    # -- HIT: return cached results
    if match:
        return cb_core.handle_hit(session, match, p_user_question,
                                    p_response_model, preview_rows=p_preview_rows).to_dict()

    # -- MISS: return agent endpoint for client to invoke
    return cb_core.handle_miss(session, p_user_question, p_normalized_user_question,
                               p_agent_name).to_dict()
$$;

-- ============================================================================
-- Harvester — back-fills SQL from agent observability logs
-- ============================================================================

DEFINE PROCEDURE {{db_name}}.{{schema_name}}.{{proc_harvest}}()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake')
IMPORTS = ('@{{db_name}}.{{schema_name}}.{{stage_name}}/cb_core.py')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
from snowflake.snowpark import Session
import cb_core

def run(session: Session) -> dict:
    """Scan AI observability events for pending MISS rows and back-fill SQL + query_id."""
    return cb_core.harvest_agent_queries(session)
$$;
