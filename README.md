# Circuit Breaker for Cortex Agent

An intercept layer for agentic data applications that reduces cost and latency by caching frequently asked questions.

## What is the Circuit Breaker?

The Circuit Breaker (CB) is an architectural pattern that sits in front of a Cortex Agent to intercept incoming natural language questions. If a question (exact or semantically similar) has been asked before, the cached SQL is re-executed directly — bypassing the agent entirely.

This is designed for **insights-only agentic applications over structured data** — applications where a Cortex Agent generates SQL queries to answer business questions.

### Why use it?

| Benefit | How |
|---------|-----|
| **Cost Reduction** | Frequent questions execute via warehouse compute instead of expensive LLM reasoning tokens |
| **Latency Reduction** | Direct SQL execution + lightweight response formatting is significantly faster than full agent orchestration |

## Architecture

```mermaid
sequenceDiagram
    participant Client as Client App
    participant CB as CB_INTERCEPT
    participant Search as Cortex Search / Table
    participant LLM as CORTEX.COMPLETE
    participant Agent as Cortex Agent
    participant Obs as Observability Logs
    participant Harvest as CB_HARVEST_TASK

    Client->>CB: CALL cb_intercept(question, params)
    CB->>CB: normalize_question(text)

    rect rgba(74, 222, 128, 0.08)
    Note right of Client: HIT PATH
    CB->>Search: exact_match / hybrid_search
    Search-->>CB: matched row (sql_text, query_id)
    CB->>CB: execute_cached_sql(sql_text)
    CB->>LLM: format_response(question, results)
    LLM-->>CB: natural language answer
    CB->>CB: update_hit (hit_count += 1)
    CB-->>Client: {path: HIT, answer, sql_text, result_preview}
    end

    rect rgba(251, 146, 60, 0.08)
    Note right of Client: MISS PATH (no match found)
    CB-->>Client: {path: MISS, agent_endpoint, question}
    Client->>Agent: POST /api/v2/.../agents/{name}:run
    Agent-->>Client: full response (SQL + results)
    Agent->>Obs: emits spans & events
    end

    rect rgba(167, 139, 250, 0.08)
    Note right of Client: HARVESTER (async, every 5 min)
    Harvest->>Obs: GET_AI_OBSERVABILITY_EVENTS (all agents)
    Obs-->>Harvest: request events + SQL execution spans
    Harvest->>Harvest: join questions with SQL, deduplicate
    Harvest->>Search: MERGE INTO cb_question_history
    Note over Search: New questions become future HITs
    end
```

### Key Components

| Component | Role |
|-----------|------|
| **CB_INTERCEPT** | Python SP — normalizes question, tries exact then hybrid match, returns HIT or MISS |
| **CB_QUESTION_HISTORY** | Table (PK: normalized question) — stores cached SQL, hit counts, recency |
| **CB_QUESTION_SEARCH** | Cortex Search Service — semantic similarity matching with confidence gating |
| **CORTEX.COMPLETE** | Formats raw SQL results into conversational answers on the HIT path |
| **CB_TPCH_AGENT** | Cortex Agent — handles MISSes with full SQL generation and multi-step reasoning |
| **CB_HARVEST_TASK** | Scheduled task — MERGEs agent-generated SQL from observability logs into the cache |

## Reference Implementation

The reference implementation uses TPC-H supply chain data with a Cortex Agent backed by a semantic view. It is deployed using [Snowflake DCM](https://docs.snowflake.com/en/developer-guide/database-change-management/about-dcm) (Database Change Management).

### Prerequisites

- Snowflake account with Cortex AI features enabled
- [SnowCLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) installed (`snow` command available)
- A role with permissions to create databases, warehouses, procedures, tasks, agents, and search services
- A named connection configured in `~/.snowflake/connections.toml`

### Project Structure

```
dcm/
├── manifest.yml                 # DCM project manifest (targets, templating)
├── deploy.sh                    # One-shot deployment script
├── pre_deploy.sql               # Creates database, schema, stage; uploads Python
├── post_deploy.sql              # Creates Cortex Search, Semantic View, Agent
├── cb_core.py                   # Core Python logic (uploaded to stage)
└── sources/definitions/
    ├── compute.sql              # DEFINE WAREHOUSE CB_WH
    ├── tables.sql               # DEFINE TABLE cb_question_history
    ├── procedures.sql           # DEFINE PROCEDURE cb_intercept, cb_harvest_agent_sql
    └── tasks.sql                # DEFINE TASK cb_harvest_task
```

### Deploy

Run the full deployment from the project root:

```bash
cd circuit-breaker-pattern
bash dcm/deploy.sh
```

This executes four steps:

1. **Pre-deploy** — Creates the `CIRCUIT_BREAKER` database, `MAIN` schema, internal stage, and uploads `cb_core.py`
2. **DCM create** — Registers the DCM project (idempotent)
3. **DCM deploy** — Deploys the warehouse, table, procedures, and task via DCM definitions
4. **Post-deploy** — Creates the Cortex Search Service, Semantic View, and Cortex Agent

You can customize the deployment with environment variables:

```bash
CONNECTION=my_connection DEPLOY_ROLE=MY_ROLE bash dcm/deploy.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `CONNECTION` | `<SnowCLI connection Name>` | Snowflake connection name |
| `DEPLOY_ROLE` | `<Configured Snowflake Role>` | Role used for deployment |
| `TARGET` | `DEV` | DCM target from manifest |

### Configuration Parameters

All tuning is done at call time via procedure parameters — there is no external config file.

| Parameter | Type | Description |
|-----------|------|-------------|
| `P_USER_QUESTION` | VARCHAR | The natural language question from the end user |
| `P_HYBRID_SEARCH_ENABLED` | BOOLEAN | When `TRUE`, falls back to Cortex Search semantic matching if no exact match is found. Set to `FALSE` for exact-only matching (lower cost, stricter) |
| `P_CONFIDENCE_THRESHOLD` | FLOAT | Minimum cosine similarity score (0.0–1.0) required for a hybrid search result to qualify as a HIT. Higher values reduce false positives but may miss paraphrased questions. Recommended: `0.90`–`0.98` |
| `P_RECENCY_WINDOW_DAYS` | NUMBER | Only match against questions asked within this many days. Older cached entries are ignored even if not expired. Controls how "fresh" a cached answer must be |
| `P_EXPIRY_THRESHOLD_DAYS` | NUMBER | Questions not asked within this many days are marked expired and excluded from matching entirely. Acts as a TTL for the cache |
| `P_RESPONSE_MODEL` | VARCHAR | The Cortex LLM model used to format SQL results into natural language on the HIT path (e.g., `'mistral-large2'`, `'llama3.1-70b'`) |
| `P_AGENT_NAME` | VARCHAR | Fully-qualified name of the Cortex Agent to route MISSes to (e.g., `'CIRCUIT_BREAKER.MAIN.CB_TPCH_AGENT'`). The interceptor builds the REST endpoint from this |
| `P_PREVIEW_ROWS` | NUMBER | Maximum number of rows to return from cached SQL execution. Limits result size for the LLM formatter and the `result_preview` field |

### Usage

Once deployed, call the interceptor from your application:

```sql
CALL CIRCUIT_BREAKER.MAIN.CB_INTERCEPT(
    'What are the top 10 customers by revenue?',  -- question
    TRUE,                                          -- hybrid_search_enabled
    0.95,                                          -- confidence_threshold
    30,                                            -- recency_window_days
    90,                                            -- expiry_threshold_days
    'mistral-large2',                              -- response_model
    'CIRCUIT_BREAKER.MAIN.CB_TPCH_AGENT',          -- agent_name
    50                                             -- preview_rows
);
```

**Response on HIT:**
```json
{
  "path": "HIT",
  "answer": "The top 10 customers by revenue are...",
  "sql_text": "SELECT ... FROM ...",
  "result_preview": "[{...}, ...]"
}
```

**Response on MISS:**
```json
{
  "path": "MISS",
  "agent_name": "CIRCUIT_BREAKER.MAIN.CB_TPCH_AGENT",
  "agent_endpoint": "/api/v2/databases/circuit_breaker/schemas/main/agents/cb_tpch_agent:run",
  "question": "What are the top 10 customers by revenue?"
}
```

On a MISS, the client calls the agent REST endpoint directly. The harvester task automatically picks up the agent's generated SQL from observability logs and caches it for future HITs.

### Resume the Harvester Task

The harvest task is suspended by default after deployment. Resume it once your agent is operational:

```sql
ALTER TASK CIRCUIT_BREAKER.MAIN.CB_HARVEST_TASK RESUME;
```

### Adapting to Your Own Data

To use the Circuit Breaker with your own agent and data:

1. **Replace the Semantic View** — Edit the `post_deploy.sql` semantic view definition to point at your tables
2. **Replace the Agent** — Update the agent spec in `post_deploy.sql` with your own tools and instructions
3. **Update the `agent_name` parameter** — Pass your agent's fully-qualified name when calling `CB_INTERCEPT`
4. **Adjust thresholds** — Tune `confidence_threshold` (semantic matching strictness) and `recency_window_days` (cache freshness) for your use case

### Further enhancements to consider

- Add bypass for questions against unstructured data (where the relevant Cortex Search is remembered and hit directly; this will only work for single-search sourced queries).

## Alternate Solution Options

### Circuit Breaker as a long running service

TBD