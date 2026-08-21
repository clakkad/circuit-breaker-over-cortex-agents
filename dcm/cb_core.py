"""
Circuit Breaker — Core Logic Module
Provides matching, caching, recording, and response formatting functions
used by the cb_intercept stored procedure.
"""

import json
import re
from dataclasses import dataclass, asdict
from datetime import datetime, timezone

from snowflake.snowpark import Session
from snowflake.core import Root


# ---------------------------------------------------------------------------
# Response data contract
# ---------------------------------------------------------------------------

@dataclass
class CbInterceptorResponse:
    """Data contract for cb_intercept stored procedure responses."""
    path: str
    answer: str = None
    sql_text: str = None
    result_preview: str = None
    agent_name: str = None
    agent_endpoint: str = None
    question: str = None

    def to_dict(self) -> dict:
        return {k: v for k, v in asdict(self).items() if v is not None}


# ---------------------------------------------------------------------------
# Text normalization
# ---------------------------------------------------------------------------

def normalize_question(q: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace."""
    q = q.lower().strip()
    q = re.sub(r'[^a-z0-9 ]', '', q)
    q = re.sub(r'\s+', ' ', q)
    return q


# ---------------------------------------------------------------------------
# Matching strategies
# ---------------------------------------------------------------------------

def hybrid_search(session: Session, question: str, recency_days: int,
                  confidence_threshold: float = 0.95):
    """Call Cortex Search Service for top-1 semantic match, gated by confidence score."""
    try:
        cortex_search_service = (
            Root(session)
            .databases["CIRCUIT_BREAKER"]
            .schemas["MAIN"]
            .cortex_search_services["CB_QUESTION_SEARCH"]
        )
        response = cortex_search_service.search(
            question,
            columns=["query_id", "sql_text", "user_query_normalized", "last_asked_at"],
            filter={
                "@and": [
                    {"@eq": {"is_expired": False}},
                    {"@lte": {"recency_days": recency_days}}
                ]
            },
            limit=1
        )
        results = response.results
        if results:
            scores = results[0].get('@scores', {})
            cosine_sim = scores.get('cosine_similarity', 0)
            if cosine_sim >= confidence_threshold:
                return results[0]
    except Exception:
        pass
    return None


def exact_match(session: Session, normalized_q: str, recency_days: int):
    """Exact match on normalized question text."""
    sql = f"""
        SELECT query_id, sql_text, user_query_normalized, last_asked_at
        FROM CIRCUIT_BREAKER.MAIN.cb_question_history
        WHERE user_query_normalized = '{normalized_q.replace("'", "''")}'
          AND is_expired = FALSE
          AND recency_days <= {recency_days}
        LIMIT 1
    """
    rows = session.sql(sql).collect()
    return rows[0].as_dict() if rows else None


# ---------------------------------------------------------------------------
# SQL execution & response formatting
# ---------------------------------------------------------------------------

def execute_cached_sql(session: Session, sql_text: str, max_rows: int = 50):
    """Execute the cached SQL and return results as JSON string."""
    try:
        rows = session.sql(sql_text).collect()
        if rows:
            result = [row.as_dict() for row in rows]
            return json.dumps(result[:max_rows], default=str)
        return "[]"
    except Exception as e:
        return json.dumps({"error": str(e)})


def format_response(session: Session, question: str, result_json: str, model: str):
    """Use CORTEX.COMPLETE to format SQL results into natural language."""
    prompt = (
        "You are a data analyst responding to a user's question. "
        "Using ONLY the query results provided below, write a direct, "
        "well-structured answer as if you queried the data yourself. "
        "Rules: "
        "- Answer the question naturally and conversationally. "
        "- Include specific numbers, names, and values from the results. "
        "- Format large numbers with commas for readability. "
        "- If the results contain a ranking or list, present it clearly. "
        "- Do NOT mention SQL, queries, JSON, or datasets — just answer the question. "
        "- If the results are limited to a subset, briefly note that more data may exist. "
        f"\n\nQuestion: {question}"
        f"\n\nData: {result_json}"
    ).replace("'", "''")

    sql = f"""
        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            '{model}',
            '{prompt}'
        ) AS answer
    """
    rows = session.sql(sql).collect()
    return rows[0]['ANSWER'] if rows else "Unable to format response."



# ---------------------------------------------------------------------------
# History table operations
# ---------------------------------------------------------------------------

# def record_question(session: Session, normalized: str,
#                     sql_text: str = None, query_id: str = None,
#                     agent_name: str = None, thread_id: int = None):
#     """Record a new unique NL question into the history table (MISS path only).
#
#     Each question is stored once. On future HITs, only update_hit is called.
#     On the MISS path, sql_text and query_id may be NULL (placeholder) until
#     the harvester back-fills them from agent observability logs.
#     """
#     escaped_n = normalized.replace("'", "''")
#     escaped_sql = f"'{sql_text.replace(chr(39), chr(39)+chr(39))}'" if sql_text else 'NULL'
#     qid_val = f"'{query_id}'" if query_id else 'NULL'
#     agent_val = f"'{agent_name}'" if agent_name else 'NULL'
#     tid_val = str(thread_id) if thread_id is not None else 'NULL'
#
#     insert_sql = f"""
#         INSERT INTO CIRCUIT_BREAKER.MAIN.cb_question_history
#             (query_id, sql_text, user_query_normalized, last_asked_at,
#              is_expired, hit_count, recency_days, agent_name, thread_id)
#         VALUES (
#             {qid_val},
#             {escaped_sql},
#             '{escaped_n}',
#             CURRENT_TIMESTAMP(),
#             FALSE,
#             0,
#             0,
#             {agent_val},
#             {tid_val}
#         )
#     """
#     session.sql(insert_sql).collect()


def update_hit(session: Session, query_id: str, recency_days: int):
    """Bump hit_count, refresh last_asked_at, and persist recency on a HIT."""
    sql = f"""
        UPDATE CIRCUIT_BREAKER.MAIN.cb_question_history
        SET hit_count = hit_count + 1,
            last_asked_at = CURRENT_TIMESTAMP(),
            recency_days = {recency_days}
        WHERE query_id = '{query_id}'
    """
    session.sql(sql).collect()


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def compute_recency(last_asked) -> int:
    """Compute days since last_asked_at."""
    if last_asked:
        if isinstance(last_asked, str):
            last_asked = datetime.fromisoformat(last_asked.replace('Z', '+00:00'))
        delta = datetime.now(timezone.utc) - last_asked.replace(tzinfo=timezone.utc)
        return delta.days
    return 0


# def is_valid_sql(sql_text) -> bool:
#     """Check if extracted SQL is non-empty and not a null literal."""
#     return bool(sql_text and sql_text.strip() and sql_text.strip().lower() != 'null')

# ---------------------------------------------------------------------------
# Path handlers (shared return contract)
# ---------------------------------------------------------------------------

def handle_hit(session: Session, match, user_question: str,
               response_model: str, preview_rows: int = 50) -> dict:
    """Process a cache HIT: execute cached SQL, format response, update stats.

    Returns:
        dict with keys: path, sql_text, result_preview
    """
    matched_query_id = match.get('query_id') or match.get('QUERY_ID')
    cached_sql = match.get('sql_text') or match.get('SQL_TEXT')
    last_asked = match.get('last_asked_at') or match.get('LAST_ASKED_AT')
    recency_days = compute_recency(last_asked)

    # Execute the matching SQL
    result_json = execute_cached_sql(session, cached_sql, max_rows=preview_rows)

    # Use the results to formulate a well-formed answer through a single LLM call
    answer = format_response(session, user_question, result_json, response_model)

    # Update hit metrics
    update_hit(session, matched_query_id, recency_days)

    return CbInterceptorResponse(
        path="HIT",
        answer=answer,
        sql_text=cached_sql,
        result_preview=result_json,
    )


def handle_miss(session: Session, user_question: str, normalized: str,
                agent_name: str) -> dict:
    """Return MISS directive with agent REST endpoint and run_id.

    The client is responsible for invoking the agent via the Cortex Agent
    Run REST API using the returned endpoint.
    """
    parts = agent_name.split('.')
    if len(parts) == 3:
        db, schema, name = parts
    else:
        db, schema, name = "CIRCUIT_BREAKER", "MAIN", agent_name

    return CbInterceptorResponse(
        path="MISS",
        agent_name=agent_name,
        agent_endpoint=f"/api/v2/databases/{db.lower()}/schemas/{schema.lower()}/agents/{name.lower()}:run",
        question=user_question,
    )


# ---------------------------------------------------------------------------
# Harvester — pulls agent SQL from observability logs via MERGE
# ---------------------------------------------------------------------------

def harvest_agent_queries(session: Session) -> dict:
    """Pull last day's questions+SQL from all accessible agents and MERGE into cb_question_history."""
    # Discover all agents accessible to the current role
    session.sql("SHOW AGENTS").collect()
    agent_rows = session.sql("""
        SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS agent_fqn
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    """).collect()

    total_merged = 0

    for row in agent_rows:
        agent_fqn = row['AGENT_FQN']
        parts = agent_fqn.split('.')
        if len(parts) != 3:
            continue
        db, schema, name = parts

        result = session.sql(f"""
            MERGE INTO CIRCUIT_BREAKER.MAIN.CB_QUESTION_HISTORY AS target
            USING (
                WITH request_events AS (
                    SELECT
                        TIMESTAMP AS request_timestamp,
                        RECORD:name::STRING AS record_name,
                        RECORD_TYPE,
                        RECORD_ATTRIBUTES,
                        RECORD_ATTRIBUTES:"ai.observability.record_id"::STRING AS record_id,
                        VALUE:"snow.ai.observability.request_body"."thread_id"::NUMBER AS thread_id,
                        VALUE:"snow.ai.observability.request_body"."messages"[0]."content"[0]."text"::STRING AS user_question,
                        VALUE:"snow.ai.observability.response_status_code"::INT AS response_status_code
                    FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
                        '{db}', '{schema}', '{name}', 'CORTEX AGENT'
                    ))
                    WHERE TIMESTAMP > DATEADD('day', -1, CURRENT_TIMESTAMP())
                      AND (
                        (RECORD_TYPE = 'EVENT' AND RECORD:name::STRING = 'CORTEX_AGENT_REQUEST')
                        OR
                        (RECORD_TYPE = 'SPAN' AND RECORD:name::STRING = 'SqlExecution_SystemSQL')
                      )
                ),
                sql_spans AS (
                    SELECT
                        RECORD_ATTRIBUTES:"ai.observability.record_id"::STRING AS record_id,
                        RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.query"::STRING AS sql_query
                    FROM request_events
                    WHERE RECORD_TYPE = 'SPAN'
                      AND RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.status"::STRING = 'SUCCESS'
                ),
                joined AS (
                    SELECT
                        re.record_id,
                        re.thread_id,
                        re.user_question,
                        re.request_timestamp,
                        ss.sql_query
                    FROM request_events re
                    INNER JOIN sql_spans ss ON re.record_id = ss.record_id
                    WHERE re.RECORD_TYPE = 'EVENT'
                      AND re.user_question IS NOT NULL
                      AND ss.sql_query IS NOT NULL
                ),
                deduped AS (
                    SELECT
                        *,
                        REGEXP_REPLACE(REGEXP_REPLACE(LOWER(TRIM(user_question)), '[^a-z0-9 ]', ''), '\\\\s+', ' ') AS user_query_normalized
                    FROM joined
                    QUALIFY ROW_NUMBER() OVER (
                        PARTITION BY user_query_normalized
                        ORDER BY request_timestamp DESC
                    ) = 1
                )
                SELECT * FROM deduped
            ) AS source
            ON target.USER_QUERY_NORMALIZED = source.user_query_normalized

            WHEN MATCHED THEN UPDATE SET
                target.QUERY_ID          = source.record_id,
                target.SQL_TEXT           = source.sql_query,
                target.THREAD_ID         = source.thread_id,
                target.LAST_ASKED_AT     = source.request_timestamp,
                target.RECENCY_DAYS      = DATEDIFF('day', source.request_timestamp, CURRENT_TIMESTAMP()),
                target.LAST_LOG_PULL_AT  = CURRENT_TIMESTAMP(),
                target.IS_EXPIRED        = FALSE

            WHEN NOT MATCHED THEN INSERT (
                QUERY_ID, SQL_TEXT, USER_QUERY_NORMALIZED, LAST_ASKED_AT,
                IS_EXPIRED, HIT_COUNT, RECENCY_DAYS, AGENT_NAME, THREAD_ID, LAST_LOG_PULL_AT
            ) VALUES (
                source.record_id,
                source.sql_query,
                source.user_query_normalized,
                source.request_timestamp,
                FALSE,
                1,
                0,
                '{agent_fqn}',
                source.thread_id,
                CURRENT_TIMESTAMP()
            )
        """).collect()

        if result:
            total_merged += result[0]['number of rows inserted'] + result[0]['number of rows updated']

    return {"merged": total_merged, "agents_scanned": len(agent_rows)}
