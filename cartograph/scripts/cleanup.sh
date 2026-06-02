#!/bin/bash
# =============================================================================
# cleanup.sh — Termina el cluster EMR de cartograph y borra SOLO lo que generó
#              este proyecto. PRESERVA el bucket y el corpus (compartidos con
#              invert_index_emr).
#
# Borra: cluster EMR + s3://<bucket>/{output,hql,logs}/ + locales.
# NO borra: el bucket ni s3://<bucket>/input/corpus.txt ni doc_map.txt
#
# Uso:
#   bash cartograph/scripts/cleanup.sh                  # lee cartograph/.emr_state
#   bash cartograph/scripts/cleanup.sh --bucket <b>
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/cartograph/.emr_state"

BUCKET=""
REGION="us-east-1"
CLUSTER_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$BUCKET" ]] && [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
  echo "  Leído desde .emr_state:"
  echo "    BUCKET=$BUCKET  |  REGION=$REGION  |  CLUSTER_ID=${CLUSTER_ID:-no guardado}"
elif [[ -z "$BUCKET" ]]; then
  echo "Uso: bash cartograph/scripts/cleanup.sh --bucket <nombre-bucket>"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Limpieza cartograph — PRESERVANDO el bucket    ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Cluster EMR : ${CLUSTER_ID:-buscar activos}"
echo "  Se borrará  : s3://$BUCKET/{output,hql,logs}/  +  locales"
echo "  Se CONSERVA : el bucket + input/corpus.txt + doc_map.txt"
echo ""
read -r -p "  ¿Continuar? [s/N] " confirm
[[ "$confirm" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
echo ""

# ── 1. Terminar cluster EMR ───────────────────────────────────────────────────
echo "[ 1/3 ] Terminando cluster EMR..."
if [[ -n "$CLUSTER_ID" ]]; then
  STATUS=$(aws emr describe-cluster \
    --cluster-id "$CLUSTER_ID" --region "$REGION" \
    --query 'Cluster.Status.State' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$STATUS" == "TERMINATED" || "$STATUS" == "TERMINATED_WITH_ERRORS" || "$STATUS" == "NOT_FOUND" ]]; then
    echo "        Cluster $CLUSTER_ID ya estaba terminado ($STATUS)."
  else
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION"
    echo "        ✓ Cluster $CLUSTER_ID terminado."
  fi
else
  ACTIVE=$(aws emr list-clusters --region "$REGION" --active \
    --query "Clusters[?Name=='InvertedIndex-Hive-cartograph'].Id" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$ACTIVE" ]]; then
    aws emr terminate-clusters --cluster-ids $ACTIVE --region "$REGION"
    echo "        ✓ Clusters terminados: $ACTIVE"
  else
    echo "        No se encontraron clusters activos."
  fi
fi

# ── 2. Borrar SOLO lo que generó cartograph (no el corpus ni el bucket) ───────
echo ""
echo "[ 2/3 ] Borrando salidas de cartograph en S3 (conservando el corpus)..."
for prefix in output hql logs; do
  if aws s3 ls "s3://$BUCKET/$prefix/" >/dev/null 2>&1; then
    aws s3 rm "s3://$BUCKET/$prefix/" --recursive
    echo "        ✓ s3://$BUCKET/$prefix/ borrado."
  else
    echo "        (s3://$BUCKET/$prefix/ no existe)"
  fi
done

# ── 3. Limpiar archivos locales ───────────────────────────────────────────────
echo ""
echo "[ 3/3 ] Limpiando archivos locales..."
rm -rf "$ROOT_DIR/cartograph/data"
rm -f  "$ROOT_DIR/cartograph/.emr_state"
echo "        ✓ cartograph/data/ y .emr_state eliminados."

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Limpieza completada (bucket preservado)        ║"
echo "╚══════════════════════════════════════════════════╝"
