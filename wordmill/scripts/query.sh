#!/bin/bash
# =============================================================================
# query.sh — Ejecuta una consulta HiveQL personalizada en el cluster activo
#
# Uso:
#   bash wordmill/scripts/query.sh "SELECT word, total FROM wm_wordcount LIMIT 5"
#   bash wordmill/scripts/query.sh "SELECT COUNT(*) FROM wm_wordcount"
#   bash wordmill/scripts/query.sh "SELECT * FROM wm_wordcount WHERE word = 'light'"
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/wordmill/.emr_state"

# ── Leer estado del cluster ───────────────────────────────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: no se encontró wordmill/.emr_state"
  echo "Asegúrate de haber ejecutado run_hive.sh primero."
  exit 1
fi
source "$STATE_FILE"

# ── Query ─────────────────────────────────────────────────────────────────────
QUERY="${1:-}"
if [[ -z "$QUERY" ]]; then
  echo "Uso: bash wordmill/scripts/query.sh \"<consulta HiveQL>\""
  echo ""
  echo "Ejemplos:"
  echo "  bash wordmill/scripts/query.sh \"SELECT word, total FROM wm_wordcount ORDER BY total DESC LIMIT 10\""
  echo "  bash wordmill/scripts/query.sh \"SELECT COUNT(*) FROM wm_wordcount\""
  echo "  bash wordmill/scripts/query.sh \"SELECT * FROM wm_wordcount WHERE word = 'light'\""
  exit 1
fi

# ── Verificar que el cluster sigue activo ────────────────────────────────────
STATUS=$(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Status.State' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$STATUS" != "WAITING" && "$STATUS" != "RUNNING" ]]; then
  echo "ERROR: el cluster $CLUSTER_ID no está activo (estado: $STATUS)"
  echo "Necesitas un cluster en estado WAITING o RUNNING."
  exit 1
fi

echo ""
echo "  Cluster : $CLUSTER_ID  ($STATUS)"
echo "  Query   : $QUERY"
echo ""

# ── Lanzar step con la query ──────────────────────────────────────────────────
STEP_ID=$(aws emr add-steps \
  --cluster-id "$CLUSTER_ID" \
  --region "$REGION" \
  --steps "[{
    \"Type\": \"CUSTOM_JAR\",
    \"Name\": \"custom-query\",
    \"ActionOnFailure\": \"CONTINUE\",
    \"Jar\": \"command-runner.jar\",
    \"Args\": [
      \"hive-script\",
      \"--run-hive-script\",
      \"--args\",
      \"-e\", \"$(echo "$QUERY" | sed 's/"/\\\\"/g')\"
    ]
  }]" \
  --query 'StepIds[0]' \
  --output text)

echo "  Step ID : $STEP_ID"
echo "  Esperando resultado..."

aws emr wait step-complete \
  --cluster-id "$CLUSTER_ID" \
  --step-id "$STEP_ID" \
  --region "$REGION"

STEP_STATUS=$(aws emr describe-step \
  --cluster-id "$CLUSTER_ID" \
  --step-id "$STEP_ID" \
  --region "$REGION" \
  --query 'Step.Status.State' --output text)

echo ""
if [[ "$STEP_STATUS" == "COMPLETED" ]]; then
  echo "── Resultado ────────────────────────────────────────────"
  aws s3 cp "s3://$BUCKET/logs/$CLUSTER_ID/steps/$STEP_ID/stdout.gz" - 2>/dev/null \
    | gunzip -c \
    || echo "(sin output — la query puede no retornar filas)"
  echo "─────────────────────────────────────────────────────────"
else
  echo "ERROR: step falló ($STEP_STATUS)"
  echo "Ver logs:"
  echo "  aws s3 cp s3://$BUCKET/logs/$CLUSTER_ID/steps/$STEP_ID/stderr.gz - | gunzip -c"
fi
