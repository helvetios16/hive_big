#!/bin/bash
# =============================================================================
# run_hive.sh — Crea cluster EMR con Hive y ejecuta WordCount
#
# Pre-requisito: texto ya subido a S3
#   python3 wordmill/scripts/build_text.py --s3 <bucket>
#
# Uso:
#   bash wordmill/scripts/run_hive.sh                          # bucket por defecto
#   bash wordmill/scripts/run_hive.sh --bucket mi-hive-wordmill
#   bash wordmill/scripts/run_hive.sh --bucket <b> --region us-west-2
# =============================================================================
set -euo pipefail

BUCKET="mi-hive-wordmill"
REGION="us-east-1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HQL_LOCAL="$ROOT_DIR/wordmill/hql/wordcount.hql"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   WordCount — Apache Hive en Amazon EMR          ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Bucket : s3://$BUCKET"
echo "  Región : $REGION"
echo ""

# ── Verificar AWS ─────────────────────────────────────────────────────────────
aws sts get-caller-identity --query 'Account' --output text > /dev/null || {
  echo "ERROR: AWS CLI no configurado."
  exit 1
}

# ── Verificar recursos en S3 ──────────────────────────────────────────────────
echo "Verificando recursos en S3..."
if ! aws s3 ls "s3://$BUCKET/input/text.txt" >/dev/null 2>&1; then
  echo "ERROR: no existe s3://$BUCKET/input/text.txt"
  echo "Ejecuta primero:"
  echo "  python3 wordmill/scripts/build_text.py --s3 $BUCKET"
  exit 1
fi
echo "✓ input/text.txt encontrado."
echo ""

# ── Subir HQL a S3 ────────────────────────────────────────────────────────────
echo "[ 1/4 ] Subiendo wordcount.hql a S3..."
aws s3 cp "$HQL_LOCAL" "s3://$BUCKET/hql/wordcount.hql"
echo "        ✓ hql/wordcount.hql  →  s3://$BUCKET/hql/"

# ── Verificar/crear roles IAM ─────────────────────────────────────────────────
echo ""
echo "[ 2/4 ] Verificando roles IAM..."
if ! aws iam get-role --role-name EMR_DefaultRole >/dev/null 2>&1; then
  echo "        Creando roles por defecto..."
  aws emr create-default-roles
  echo "        ✓ Roles creados."
else
  echo "        ✓ Roles ya existen."
fi

# ── Trap: limpiar cluster si se interrumpe ────────────────────────────────────
CLUSTER_ID=""
cleanup() {
  if [ -n "$CLUSTER_ID" ]; then
    echo ""
    echo "Interrupción detectada. Terminando cluster $CLUSTER_ID ..."
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION" 2>/dev/null || true
    echo "Cluster terminado."
  fi
  exit 1
}
trap cleanup INT TERM

# ── Crear cluster EMR con Hadoop + Hive ───────────────────────────────────────
echo ""
echo "[ 3/4 ] Creando cluster EMR (1 master + 1 core m4.large)..."
echo "        Aplicaciones: Hadoop + Hive"
echo "        (puede tardar 5-10 min)"

CLUSTER_ID=$(aws emr create-cluster \
  --name "WordCount-Hive-wordmill" \
  --release-label emr-7.0.0 \
  --applications Name=Hadoop Name=Hive \
  --instance-groups \
    "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m4.large" \
    "InstanceGroupType=CORE,InstanceCount=1,InstanceType=m4.large" \
  --use-default-roles \
  --region "$REGION" \
  --log-uri "s3://$BUCKET/logs/" \
  --no-auto-terminate \
  --enable-debugging \
  --query 'ClusterId' \
  --output text)

echo "        Cluster ID: $CLUSTER_ID"
echo "        Esperando estado WAITING..."
aws emr wait cluster-running --cluster-id "$CLUSTER_ID" --region "$REGION"
echo "        ✓ Cluster listo."

# ── Lanzar step de Hive ───────────────────────────────────────────────────────
echo ""
echo "[ 4/4 ] Lanzando WordCount con Hive..."

STEP_ID=$(aws emr add-steps \
  --cluster-id "$CLUSTER_ID" \
  --region "$REGION" \
  --steps "[{
    \"Type\": \"CUSTOM_JAR\",
    \"Name\": \"WordCount-HiveQL\",
    \"ActionOnFailure\": \"CONTINUE\",
    \"Jar\": \"command-runner.jar\",
    \"Args\": [
      \"hive-script\",
      \"--run-hive-script\",
      \"--args\",
      \"-f\",       \"s3://$BUCKET/hql/wordcount.hql\",
      \"-hivevar\", \"INPUT=s3://$BUCKET/input/\",
      \"-hivevar\", \"OUTPUT=s3://$BUCKET/output/\"
    ]
  }]" \
  --query 'StepIds[0]' \
  --output text)

echo "        Step ID: $STEP_ID"
echo "        Esperando que el job termine..."
aws emr wait step-complete \
  --cluster-id "$CLUSTER_ID" \
  --step-id "$STEP_ID" \
  --region "$REGION"

STATUS=$(aws emr describe-step \
  --cluster-id "$CLUSTER_ID" \
  --step-id "$STEP_ID" \
  --region "$REGION" \
  --query 'Step.Status.State' \
  --output text)

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
if [[ "$STATUS" == "COMPLETED" ]]; then
  echo "║   JOB COMPLETADO EXITOSAMENTE                    ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "  Resultados en : s3://$BUCKET/output/"
  echo "  Logs en       : s3://$BUCKET/logs/"
  echo ""
  echo "  ── Ver archivos de salida ───────────────────────"
  echo "  aws s3 ls s3://$BUCKET/output/"
  echo ""
  echo "  ── Ver top 20 palabras ──────────────────────────"
  # Descarga todos los part-files y ordena por frecuencia desc
  echo "  aws s3 cp s3://$BUCKET/output/ ./output/ --recursive --exclude \"*_SUCCESS\""
  echo "  cat output/0* | sort -t\$'\\t' -k2 -rn | head -20"
  echo ""
  echo "  ── Terminar cluster (evitar costos) ─────────────"
  echo "  aws emr terminate-clusters --cluster-ids $CLUSTER_ID"
else
  echo "║   JOB FALLÓ — Estado: $STATUS                    ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "  Terminando cluster para evitar costos..."
  aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION" 2>/dev/null || true
  echo "  Cluster $CLUSTER_ID terminado."
  echo ""
  echo "  Ver logs:"
  echo "  aws s3 cp s3://$BUCKET/logs/$CLUSTER_ID/steps/$STEP_ID/stderr.gz - | gunzip -c"
  exit 1
fi

# Guardar estado para cleanup
echo "CLUSTER_ID=$CLUSTER_ID" > "$ROOT_DIR/wordmill/.emr_state"
echo "BUCKET=$BUCKET"        >> "$ROOT_DIR/wordmill/.emr_state"
echo "REGION=$REGION"        >> "$ROOT_DIR/wordmill/.emr_state"
echo ""
echo "  (IDs guardados en wordmill/.emr_state)"
