#!/bin/bash
# =============================================================================
# cleanup.sh — Elimina cluster EMR, bucket S3 y archivos locales de taxiscope
#
# Uso:
#   bash taxiscope/scripts/cleanup.sh                  # lee taxiscope/.emr_state
#   bash taxiscope/scripts/cleanup.sh --bucket <b>     # especifica bucket
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/taxiscope/.emr_state"

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
  echo "    BUCKET=$BUCKET"
  echo "    REGION=$REGION"
  echo "    CLUSTER_ID=${CLUSTER_ID:-no guardado}"
elif [[ -z "$BUCKET" ]]; then
  echo "Uso: bash taxiscope/scripts/cleanup.sh --bucket <nombre-bucket>"
  echo "     (o ejecuta run_hive.sh primero para generar .emr_state)"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Limpieza taxiscope — Recursos de AWS           ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Se eliminará:"
echo "    • Cluster EMR  : ${CLUSTER_ID:-buscar activos en la cuenta}"
echo "    • Bucket S3    : s3://$BUCKET  (incluye raw/ con los Parquet)"
echo "    • Local        : taxiscope/.emr_state"
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
    --query "Clusters[?Name=='TaxiTrips-Hive-taxiscope'].Id" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$ACTIVE" ]]; then
    aws emr terminate-clusters --cluster-ids $ACTIVE --region "$REGION"
    echo "        ✓ Clusters terminados: $ACTIVE"
  else
    echo "        No se encontraron clusters activos."
  fi
fi

# ── 2. Vaciar y eliminar bucket S3 ────────────────────────────────────────────
echo ""
echo "[ 2/3 ] Eliminando bucket S3: s3://$BUCKET ..."
if aws s3 ls "s3://$BUCKET" 2>/dev/null; then
  aws s3 rm "s3://$BUCKET" --recursive
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
  echo "        ✓ Bucket eliminado."
else
  echo "        Bucket no existe o ya fue eliminado."
fi

# ── 3. Limpiar archivos locales ───────────────────────────────────────────────
echo ""
echo "[ 3/3 ] Limpiando archivos locales..."
rm -f "$ROOT_DIR/taxiscope/.emr_state"
echo "        ✓ taxiscope/.emr_state eliminado."

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Limpieza completada                            ║"
echo "╚══════════════════════════════════════════════════╝"
