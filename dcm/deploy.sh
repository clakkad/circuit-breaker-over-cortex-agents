#!/usr/bin/env bash
# ============================================================================
# Circuit Breaker — Full Deployment Script
# ============================================================================
# Runs the complete deployment pipeline:
#   1. Pre-deploy  (database, schema, stage, Python upload)
#   2. DCM create  (register project if not exists)
#   3. DCM deploy  (tables, warehouse, procedures, tasks)
#   4. Post-deploy (cortex search, semantic view, agent)
#
# Usage:
#   cd circuit-breaker-pattern
#   bash dcm/deploy.sh
#
# Options (environment variables):
#   CONNECTION   — Snowflake connection name  (default: coco_cli_uib27272)
#   DEPLOY_ROLE  — Role for deployment        (default: COCO_CLI_SANDBOX_ROLE)
#   TARGET       — DCM target from manifest   (default: DEV)
# ============================================================================

set -euo pipefail

CONNECTION="${CONNECTION:-coco_cli_uib27272}"
DEPLOY_ROLE="${DEPLOY_ROLE:-COCO_CLI_SANDBOX_ROLE}"
TARGET="${TARGET:-DEV}"
PROJECT_ID="CIRCUIT_BREAKER.DCM_HOME.CB_DCM"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Circuit Breaker — Deployment                               ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Connection:  $CONNECTION"
echo "║  Role:        $DEPLOY_ROLE"
echo "║  Target:      $TARGET"
echo "║  Project:     $PROJECT_ID"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# --------------------------------------------------------------------------
# Step 1: Pre-deploy (database, schema, stage, Python upload)
# --------------------------------------------------------------------------
echo "▶ [1/4] Running pre-deploy (database, schema, stage, Python upload)..."
snow sql -f "$SCRIPT_DIR/pre_deploy.sql" \
  -c "$CONNECTION" \
  -D "DEPLOY_ROLE=$DEPLOY_ROLE"
echo "  ✓ Pre-deploy complete."
echo ""

# --------------------------------------------------------------------------
# Step 2: Register DCM project (idempotent — fails silently if exists)
# --------------------------------------------------------------------------
echo "▶ [2/4] Ensuring DCM project is registered..."
snow dcm create "$PROJECT_ID" -c "$CONNECTION" 2>/dev/null || true
echo "  ✓ Project registered."
echo ""

# --------------------------------------------------------------------------
# Step 3: DCM deploy (warehouse, table, procedures, task)
# --------------------------------------------------------------------------
echo "▶ [3/4] Running DCM deploy..."
cd "$SCRIPT_DIR"
snow dcm plan "$PROJECT_ID" -c "$CONNECTION" --target "$TARGET" --save-output
echo ""
echo "  Plan complete. Deploying..."
snow dcm deploy "$PROJECT_ID" -c "$CONNECTION" --target "$TARGET"
echo "  ✓ DCM deploy complete."
echo ""

# --------------------------------------------------------------------------
# Step 4: Post-deploy (cortex search, semantic view, agent)
# --------------------------------------------------------------------------
echo "▶ [4/4] Running post-deploy (search service, semantic view, agent)..."
cd "$PROJECT_ROOT"
snow sql -f "$SCRIPT_DIR/post_deploy.sql" -c "$CONNECTION"
echo "  ✓ Post-deploy complete."
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "  Deployment finished successfully."
echo "═══════════════════════════════════════════════════════════════"
