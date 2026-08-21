-- ============================================================================
-- Circuit Breaker — Post-Deploy Script (consolidated)
-- ============================================================================
-- Run AFTER `snow dcm deploy`. Order: search → semantic view → agent.
--
-- Usage:
--   snow sql -f dcm/post_deploy.sql -c coco_cli_uib27272
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Cortex Search Service
-- ----------------------------------------------------------------------------

USE SCHEMA CIRCUIT_BREAKER.MAIN;

CREATE OR REPLACE CORTEX SEARCH SERVICE cb_question_search
    ON user_query_normalized
    ATTRIBUTES is_expired, recency_days
    WAREHOUSE = COCO_SANDBOX_WH
    TARGET_LAG = '1 minute'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
AS (
    SELECT
        query_id,
        user_query_normalized,
        sql_text,
        is_expired,
        recency_days,
        last_asked_at
    FROM cb_question_history
    WHERE sql_text IS NOT NULL
);

-- ----------------------------------------------------------------------------
-- 2. Semantic View (TPCH Supply Chain Analytics)
-- ----------------------------------------------------------------------------

CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(
  'CIRCUIT_BREAKER.MAIN',
  $$
name: tpch_analytics_sv
description: >-
  TPC-H benchmark data model for supply chain analytics. Covers customers,
  orders, line items, parts, suppliers, nations, and regions. Used for
  analyzing revenue, shipping performance, supply costs, and customer
  purchasing patterns.
tables:
  - name: REGION
    description: Region data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: REGION
    primary_key:
      columns:
        - R_REGIONKEY
    dimensions:
      - name: R_REGIONKEY
        expr: R_REGIONKEY
        data_type: NUMBER
      - name: R_NAME
        expr: R_NAME
        data_type: VARCHAR
      - name: R_COMMENT
        expr: R_COMMENT
        data_type: VARCHAR

  - name: NATION
    description: Nation data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: NATION
    primary_key:
      columns:
        - N_NATIONKEY
    dimensions:
      - name: N_NATIONKEY
        expr: N_NATIONKEY
        data_type: NUMBER
      - name: N_NAME
        expr: N_NAME
        data_type: VARCHAR
      - name: N_REGIONKEY
        expr: N_REGIONKEY
        data_type: NUMBER
      - name: N_COMMENT
        expr: N_COMMENT
        data_type: VARCHAR

  - name: CUSTOMER
    description: Customer data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: CUSTOMER
    primary_key:
      columns:
        - C_CUSTKEY
    dimensions:
      - name: C_CUSTKEY
        expr: C_CUSTKEY
        data_type: NUMBER
      - name: C_NAME
        expr: C_NAME
        data_type: VARCHAR
      - name: C_ADDRESS
        expr: C_ADDRESS
        data_type: VARCHAR
      - name: C_NATIONKEY
        expr: C_NATIONKEY
        data_type: NUMBER
      - name: C_PHONE
        expr: C_PHONE
        data_type: VARCHAR
      - name: C_MKTSEGMENT
        expr: C_MKTSEGMENT
        data_type: VARCHAR
      - name: C_COMMENT
        expr: C_COMMENT
        data_type: VARCHAR
    facts:
      - name: C_ACCTBAL
        expr: C_ACCTBAL
        data_type: NUMBER

  - name: SUPPLIER
    description: Supplier data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: SUPPLIER
    primary_key:
      columns:
        - S_SUPPKEY
    dimensions:
      - name: S_SUPPKEY
        expr: S_SUPPKEY
        data_type: NUMBER
      - name: S_NAME
        expr: S_NAME
        data_type: VARCHAR
      - name: S_ADDRESS
        expr: S_ADDRESS
        data_type: VARCHAR
      - name: S_NATIONKEY
        expr: S_NATIONKEY
        data_type: NUMBER
      - name: S_PHONE
        expr: S_PHONE
        data_type: VARCHAR
      - name: S_COMMENT
        expr: S_COMMENT
        data_type: VARCHAR
    facts:
      - name: S_ACCTBAL
        expr: S_ACCTBAL
        data_type: NUMBER

  - name: PART
    description: Part data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: PART
    primary_key:
      columns:
        - P_PARTKEY
    dimensions:
      - name: P_PARTKEY
        expr: P_PARTKEY
        data_type: NUMBER
      - name: P_NAME
        expr: P_NAME
        data_type: VARCHAR
      - name: P_MFGR
        expr: P_MFGR
        data_type: VARCHAR
      - name: P_BRAND
        expr: P_BRAND
        data_type: VARCHAR
      - name: P_TYPE
        expr: P_TYPE
        data_type: VARCHAR
      - name: P_SIZE
        expr: P_SIZE
        data_type: NUMBER
      - name: P_CONTAINER
        expr: P_CONTAINER
        data_type: VARCHAR
      - name: P_COMMENT
        expr: P_COMMENT
        data_type: VARCHAR
    facts:
      - name: P_RETAILPRICE
        expr: P_RETAILPRICE
        data_type: NUMBER

  - name: PARTSUPP
    description: Partsupp data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: PARTSUPP
    dimensions:
      - name: PS_PARTKEY
        expr: PS_PARTKEY
        data_type: NUMBER
      - name: PS_SUPPKEY
        expr: PS_SUPPKEY
        data_type: NUMBER
      - name: PS_AVAILQTY
        expr: PS_AVAILQTY
        data_type: NUMBER
      - name: PS_COMMENT
        expr: PS_COMMENT
        data_type: VARCHAR
    facts:
      - name: PS_SUPPLYCOST
        expr: PS_SUPPLYCOST
        data_type: NUMBER

  - name: ORDERS
    description: Orders data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: ORDERS
    primary_key:
      columns:
        - O_ORDERKEY
    dimensions:
      - name: O_ORDERKEY
        expr: O_ORDERKEY
        data_type: NUMBER
      - name: O_CUSTKEY
        expr: O_CUSTKEY
        data_type: NUMBER
      - name: O_ORDERSTATUS
        expr: O_ORDERSTATUS
        data_type: VARCHAR
      - name: O_ORDERPRIORITY
        expr: O_ORDERPRIORITY
        data_type: VARCHAR
      - name: O_CLERK
        expr: O_CLERK
        data_type: VARCHAR
      - name: O_SHIPPRIORITY
        expr: O_SHIPPRIORITY
        data_type: NUMBER
      - name: O_COMMENT
        expr: O_COMMENT
        data_type: VARCHAR
    time_dimensions:
      - name: O_ORDERDATE
        expr: O_ORDERDATE
        data_type: DATE
    facts:
      - name: O_TOTALPRICE
        expr: O_TOTALPRICE
        data_type: NUMBER

  - name: LINEITEM
    description: Lineitem data as defined by TPC-H
    base_table:
      database: SFC_SAMPLE_DATA
      schema: TPCH_SF1000
      table: LINEITEM
    dimensions:
      - name: L_ORDERKEY
        expr: L_ORDERKEY
        data_type: NUMBER
      - name: L_PARTKEY
        expr: L_PARTKEY
        data_type: NUMBER
      - name: L_SUPPKEY
        expr: L_SUPPKEY
        data_type: NUMBER
      - name: L_LINENUMBER
        expr: L_LINENUMBER
        data_type: NUMBER
      - name: L_RETURNFLAG
        expr: L_RETURNFLAG
        data_type: VARCHAR
      - name: L_LINESTATUS
        expr: L_LINESTATUS
        data_type: VARCHAR
      - name: L_SHIPINSTRUCT
        expr: L_SHIPINSTRUCT
        data_type: VARCHAR
      - name: L_SHIPMODE
        expr: L_SHIPMODE
        data_type: VARCHAR
      - name: L_COMMENT
        expr: L_COMMENT
        data_type: VARCHAR
    time_dimensions:
      - name: L_SHIPDATE
        expr: L_SHIPDATE
        data_type: DATE
      - name: L_COMMITDATE
        expr: L_COMMITDATE
        data_type: DATE
      - name: L_RECEIPTDATE
        expr: L_RECEIPTDATE
        data_type: DATE
    facts:
      - name: L_QUANTITY
        expr: L_QUANTITY
        data_type: NUMBER
      - name: L_EXTENDEDPRICE
        expr: L_EXTENDEDPRICE
        data_type: NUMBER
      - name: L_DISCOUNT
        expr: L_DISCOUNT
        data_type: NUMBER
      - name: L_TAX
        expr: L_TAX
        data_type: NUMBER

relationships:
  - name: LINEITEM_TO_ORDERS
    left_table: LINEITEM
    right_table: ORDERS
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: L_ORDERKEY
        right_column: O_ORDERKEY
  - name: CUSTOMER_TO_NATION
    left_table: CUSTOMER
    right_table: NATION
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: C_NATIONKEY
        right_column: N_NATIONKEY
  - name: LINEITEM_TO_PART
    left_table: LINEITEM
    right_table: PART
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: L_PARTKEY
        right_column: P_PARTKEY
  - name: LINEITEM_TO_SUPPLIER
    left_table: LINEITEM
    right_table: SUPPLIER
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: L_SUPPKEY
        right_column: S_SUPPKEY
  - name: NATION_TO_REGION
    left_table: NATION
    right_table: REGION
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: N_REGIONKEY
        right_column: R_REGIONKEY
  - name: ORDERS_TO_CUSTOMER
    left_table: ORDERS
    right_table: CUSTOMER
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: O_CUSTKEY
        right_column: C_CUSTKEY
  - name: PARTSUPP_TO_PART
    left_table: PARTSUPP
    right_table: PART
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: PS_PARTKEY
        right_column: P_PARTKEY
  - name: PARTSUPP_TO_SUPPLIER
    left_table: PARTSUPP
    right_table: SUPPLIER
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: PS_SUPPKEY
        right_column: S_SUPPKEY
  - name: SUPPLIER_TO_NATION
    left_table: SUPPLIER
    right_table: NATION
    join_type: inner
    relationship_type: many_to_one
    relationship_columns:
      - left_column: S_NATIONKEY
        right_column: N_NATIONKEY
  $$,
  FALSE
);

-- ----------------------------------------------------------------------------
-- 3. Cortex Agent (depends on semantic view above)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE AGENT CIRCUIT_BREAKER.MAIN.cb_tpch_agent
FROM SPECIFICATION $$
{
  "models": {
    "orchestration": "auto"
  },
  "orchestration": {
    "budget": {
      "seconds": 60,
      "tokens": 16000
    }
  },
  "instructions": {
    "orchestration": "Use the tpch_analyst tool for all questions about orders, revenue, customers, suppliers, parts, nations, and regions. Always attempt to answer from data rather than general knowledge.",
    "response": "You are a supply chain analytics assistant for TPC-H data. Be concise and include specific numbers from query results. If a query returns data, summarize the key findings."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "tpch_analyst",
        "description": "Answers questions about TPC-H supply chain data including orders, line items, customers, suppliers, parts, nations, and regions. Use for revenue analysis, shipping performance, supply costs, and customer purchasing patterns."
      }
    }
  ],
  "tool_resources": {
    "tpch_analyst": {
      "execution_environment": {
        "query_timeout": 299,
        "type": "warehouse",
        "warehouse": "CB_WH"
      },
      "semantic_view": "CIRCUIT_BREAKER.MAIN.TPCH_ANALYTICS_SV"
    }
  }
}
$$;
