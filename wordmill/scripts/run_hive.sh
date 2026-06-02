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
KEY_PAIR=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HQL_LOCAL="$ROOT_DIR/wordmill/hql/setup.hql"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)   BUCKET="$2";   shift 2 ;;
    --region)   REGION="$2";   shift 2 ;;
    --key-pair) KEY_PAIR="$2"; shift 2 ;;
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
echo "[ 1/4 ] Subiendo setup.hql a S3..."
aws s3 cp "$HQL_LOCAL" "s3://$BUCKET/hql/setup.hql"
echo "        ✓ hql/setup.hql  →  s3://$BUCKET/hql/"

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

# ── Espera con timer ──────────────────────────────────────────────────────────
# Sondea el estado e imprime el tiempo transcurrido cada POLL segundos, en vez
# de bloquear en silencio (CloudShell se desconecta tras ~20-30 min sin
# actividad). Args: $1=descripción  $2=comando-de-estado  $3=estados-OK(regex)
#                   $4=estados-FALLO(regex)
POLL=30
LAST_ELAPSED=""   # duración (mm:ss) de la última etapa esperada
wait_con_timer() {
  local label="$1" status_cmd="$2" ok_re="$3" fail_re="$4"
  local start=$SECONDS state elapsed mmss
  while true; do
    state=$(eval "$status_cmd" 2>/dev/null || echo "?")
    elapsed=$((SECONDS - start))
    mmss=$(printf "%02d:%02d" $((elapsed / 60)) $((elapsed % 60)))
    LAST_ELAPSED="$mmss"
    printf "\r        [%s] %s: %-22s" "$mmss" "$label" "$state"
    if [[ "$state" =~ $ok_re ]];   then printf "\n"; return 0; fi
    if [[ "$state" =~ $fail_re ]]; then printf "\n"; return 1; fi
    sleep "$POLL"
  done
}

# ── Crear cluster EMR con Hadoop + Hive ───────────────────────────────────────
echo ""
echo "[ 3/4 ] Creando cluster EMR (1 master + 1 core m4.large)..."
echo "        Aplicaciones: Hadoop + Hive"
echo "        (puede tardar 5-10 min)"

EC2_ATTRS=""
if [[ -n "$KEY_PAIR" ]]; then
  EC2_ATTRS="--ec2-attributes KeyName=$KEY_PAIR"
  echo "        Key pair : $KEY_PAIR"
fi

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
  $EC2_ATTRS \
  --query 'ClusterId' \
  --output text)

echo "        Cluster ID: $CLUSTER_ID"

# Guardar estado YA: si CloudShell se cae, el cluster sigue vivo
# (--no-auto-terminate) y puedes reconectar / limpiar con estos IDs.
{
  echo "CLUSTER_ID=$CLUSTER_ID"
  echo "BUCKET=$BUCKET"
  echo "REGION=$REGION"
} > "$ROOT_DIR/wordmill/.emr_state"

echo "        (IDs guardados en wordmill/.emr_state)"
echo "        Esperando estado WAITING..."
wait_con_timer "cluster" \
  "aws emr describe-cluster --cluster-id $CLUSTER_ID --region $REGION --query Cluster.Status.State --output text" \
  '^(WAITING|RUNNING)$' \
  '^(TERMINATED|TERMINATED_WITH_ERRORS)$' || {
    echo "ERROR: el cluster no llegó a estado activo."
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION" 2>/dev/null || true
    exit 1
  }
T_CLUSTER="$LAST_ELAPSED"
echo "        ✓ Cluster listo  (aprovisionamiento: $T_CLUSTER)"

# ── Lanzar step de Hive (solo prepara la tabla de entrada) ────────────────────
echo ""
echo "[ 4/4 ] Preparando tabla de entrada (wm_input) con Hive..."

STEP_ID=$(aws emr add-steps \
  --cluster-id "$CLUSTER_ID" \
  --region "$REGION" \
  --steps "[{
    \"Type\": \"CUSTOM_JAR\",
    \"Name\": \"Setup-Input-Hive\",
    \"ActionOnFailure\": \"CONTINUE\",
    \"Jar\": \"command-runner.jar\",
    \"Args\": [
      \"hive-script\",
      \"--run-hive-script\",
      \"--args\",
      \"-f\",       \"s3://$BUCKET/hql/setup.hql\",
      \"-hivevar\", \"INPUT=s3://$BUCKET/input/\"
    ]
  }]" \
  --query 'StepIds[0]' \
  --output text)

echo "        Step ID: $STEP_ID"
echo "        Esperando que el job termine..."
wait_con_timer "step" \
  "aws emr describe-step --cluster-id $CLUSTER_ID --step-id $STEP_ID --region $REGION --query Step.Status.State --output text" \
  '^COMPLETED$' \
  '^(FAILED|CANCELLED|INTERRUPTED)$' || true
T_STEP="$LAST_ELAPSED"
echo "        Duración del step (setup tabla): $T_STEP"

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
  echo "║   TABLA DE ENTRADA LISTA                         ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "  Tabla creada  : wm_input  (texto crudo en S3, SIN contar)"
  echo "  Logs en       : s3://$BUCKET/logs/"
  echo ""
  echo "  ── Tiempos ──────────────────────────────────────"
  echo "    Aprovisionar cluster : $T_CLUSTER"
  echo "    Setup tabla (step)   : $T_STEP"
  echo ""
  echo "  El conteo NO está precalculado: ejecútalo tú mismo en la"
  echo "  sesión interactiva para medir cuánto tarda Hive."
  echo ""
  echo "  ── Abrir sesión Hive (requiere --key-pair en este paso) ──"
  echo "  bash wordmill/scripts/hive_shell.sh"
  echo ""
  echo "  Dentro de Hive, pega el conteo (top 10) — ver wordmill/hql/queries.hql:"
  echo "    SELECT word, COUNT(*) AS total FROM wm_input"
  echo "    LATERAL VIEW EXPLODE(SPLIT(LOWER(line),'[^a-z]+')) t AS word"
  echo "    WHERE LENGTH(word) > 1 GROUP BY word ORDER BY total DESC LIMIT 10;"
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

# (CLUSTER_ID/BUCKET/REGION ya quedaron en wordmill/.emr_state al crear el cluster)
