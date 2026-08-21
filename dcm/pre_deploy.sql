-- ============================================================================
-- Circuit Breaker — Pre-Deploy Script
-- ============================================================================
-- Run BEFORE `snow dcm plan` / `snow dcm deploy`.
-- Creates objects that DCM cannot manage via DEFINE:
--   1. Database & schemas (parent containers for the DCM project)
--   2. Internal stage for Python modules + file upload
--   3. Network rule, secret, and external access integration (commented out — not needed)
--
-- Configuration:
--   Set these session variables before running, or pass via CLI:
--     snow sql -f dcm/pre_deploy.sql -c coco_cli_uib27272 \
--       -D "PAT_TOKEN=<your-token>" \
--       -D "SNOWFLAKE_HOST=sfsenorthamerica-clakkad.snowflakecomputing.com" \
--       -D "DEPLOY_ROLE=COCO_CLI_SANDBOX_ROLE"
-- ============================================================================

-- Configurable parameters (override with -D on the CLI)
-- SET PAT_TOKEN = '&{PAT_TOKEN}';
-- SET SNOWFLAKE_HOST = '&{SNOWFLAKE_HOST}';
SET DEPLOY_ROLE = '&{DEPLOY_ROLE}';

USE ROLE IDENTIFIER($DEPLOY_ROLE);

-- ----------------------------------------------------------------------------
-- 1. Database & Schemas
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS CIRCUIT_BREAKER;
CREATE SCHEMA IF NOT EXISTS CIRCUIT_BREAKER.DCM_HOME;
CREATE SCHEMA IF NOT EXISTS CIRCUIT_BREAKER.MAIN;

-- ----------------------------------------------------------------------------
-- 2. Internal Stage + Python Module Upload
-- ----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS CIRCUIT_BREAKER.MAIN.CB_PYTHON_MODULES
    COMMENT = 'Internal stage for Python modules (cb_core.py, cb_benchmark.py)';

PUT file://./cb_core.py @CIRCUIT_BREAKER.MAIN.CB_PYTHON_MODULES
    AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

-- ----------------------------------------------------------------------------
-- 3. Network Rule (commented out — procedure no longer needs EAI)
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE NETWORK RULE CIRCUIT_BREAKER.MAIN.CB_SNOWFLAKE_API_RULE
--     MODE = EGRESS
--     TYPE = HOST_PORT
--     VALUE_LIST = ('&{SNOWFLAKE_HOST}:443')
--     COMMENT = 'Allows egress to Snowflake REST API for Cortex Agent calls';

-- ----------------------------------------------------------------------------
-- 4. Secret (PAT) (commented out — procedure no longer needs EAI)
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE SECRET CIRCUIT_BREAKER.MAIN.CB_PAT_SECRET
--     TYPE = GENERIC_STRING
--     SECRET_STRING = $PAT_TOKEN
--     COMMENT = 'Programmatic Access Token for Cortex Agent REST API';

-- ----------------------------------------------------------------------------
-- 5. External Access Integration (commented out — procedure no longer needs EAI)
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION CB_SNOWFLAKE_API_EAI
--     ALLOWED_NETWORK_RULES = (CIRCUIT_BREAKER.MAIN.CB_SNOWFLAKE_API_RULE)
--     ALLOWED_AUTHENTICATION_SECRETS = (CIRCUIT_BREAKER.MAIN.CB_PAT_SECRET)
--     ENABLED = TRUE
--     COMMENT = 'External access for Circuit Breaker procedures to call Snowflake REST API';

-- ----------------------------------------------------------------------------
-- 6. Grant integration usage to the project role (commented out)
-- ----------------------------------------------------------------------------
-- GRANT USAGE ON INTEGRATION CB_SNOWFLAKE_API_EAI TO ROLE IDENTIFIER($DEPLOY_ROLE);
