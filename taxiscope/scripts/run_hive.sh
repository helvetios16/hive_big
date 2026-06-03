#!/bin/bash
# =============================================================================
# run_hive.sh — Crea cluster EMR con Hive y prepara el dataset NYC Taxi
#
# Pre-requisito: Parquet ya subidos a S3
#   bash taxiscope/scripts/download_data.sh --bucket <b>
#
# Uso:
#   bash taxiscope/scripts/run_hive.sh --bucket <b> --key-pair <kp>
#   bash taxiscope/scripts/run_hive.sh --bucket <b> --key-pair <kp> --partition
#   bash taxiscope/scripts/run_hive.sh --bucket <b> --core-count 3 --partition
#
# Flags:
#   --bucket <b>          bucket S3 con raw/*.parquet ya subido
#   --key-pair <kp>       habilita la sesión Hive interactiva (hive_shell.sh)
#   --partition           ejecuta también el particionamiento (partition.hql)
#                         como step y mide su tiempo (si no, lo haces a mano)
#   --core-count <n>      nº de nodos CORE (default 6)
#   --instance-type <t>   tipo de instancia (default m4.large)
#   --region <r>          región AWS (default us-east-1)
# =============================================================================
set -euo pipefail

BUCKET="mi-hive-taxi"
REGION="us-east-1"
KEY_PAIR=""
CORE_COUNT=6
INSTANCE_TYPE="m4.large"
DO_PARTITION=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HQL_DIR="$ROOT_DIR/taxiscope/hql"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)        BUCKET="$2";        shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --key-pair)      KEY_PAIR="$2";      shift 2 ;;
    --core-count)    CORE_COUNT="$2";    shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --partition)     DO_PARTITION=1;     shift   ;;
    *) shift ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   NYC Taxi Trips — Apache Hive en Amazon EMR     ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Bucket : s3://$BUCKET"
echo "  Región : $REGION"
echo "  Nodos  : 1 master + $CORE_COUNT core ($INSTANCE_TYPE)"
echo "  Partic.: $([[ $DO_PARTITION -eq 1 ]] && echo 'sí (step)' || echo 'manual (interactivo)')"
echo ""

# ── Verificar AWS ─────────────────────────────────────────────────────────────
aws sts get-caller-identity --query 'Account' --output text > /dev/null || {
  echo "ERROR: AWS CLI no configurado."
  exit 1
}

# ── Verificar recursos en S3 (al menos una de las dos eras) ───────────────────
echo "Verificando recursos en S3..."
HAS_A=$(aws s3 ls "s3://$BUCKET/raw_a/" 2>/dev/null | grep -c '\.parquet' || true)
HAS_B=$(aws s3 ls "s3://$BUCKET/raw_b/" 2>/dev/null | grep -c '\.parquet' || true)
if [[ "$HAS_A" -eq 0 && "$HAS_B" -eq 0 ]]; then
  echo "ERROR: no hay .parquet en s3://$BUCKET/raw_a/ ni raw_b/"
  echo "Ejecuta primero:"
  echo "  bash taxiscope/scripts/download_data.sh --bucket $BUCKET --years 2020-2025"
  exit 1
fi
echo "✓ Parquet en S3  (raw_a: $HAS_A archivos, raw_b: $HAS_B archivos)"
echo ""

# ── Subir HQL a S3 ────────────────────────────────────────────────────────────
echo "[ 1/4 ] Subiendo HQL a S3..."
aws s3 cp "$HQL_DIR/setup.hql"     "s3://$BUCKET/hql/setup.hql"
aws s3 cp "$HQL_DIR/partition.hql" "s3://$BUCKET/hql/partition.hql"
aws s3 cp "$HQL_DIR/queries.hql"   "s3://$BUCKET/hql/queries.hql"
echo "        ✓ hql/*.hql  →  s3://$BUCKET/hql/"

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

# Lanza un step Hive (hive -f sobre un .hql en S3) y espera con timer.
# Args: $1=nombre-step  $2=ruta-s3-hql  [$3.. = hivevars "K=V" (0 o más)]
# Devuelve el tiempo en LAST_ELAPSED y deja STEP_ID global.
run_hive_step() {
  local name="$1" hql_s3="$2"; shift 2
  local args="\"hive-script\",\"--run-hive-script\",\"--args\",\"-f\",\"$hql_s3\""
  local hv
  for hv in "$@"; do
    args="$args,\"-hivevar\",\"$hv\""
  done
  STEP_ID=$(aws emr add-steps \
    --cluster-id "$CLUSTER_ID" --region "$REGION" \
    --steps "[{\"Type\":\"CUSTOM_JAR\",\"Name\":\"$name\",\"ActionOnFailure\":\"CONTINUE\",\"Jar\":\"command-runner.jar\",\"Args\":[$args]}]" \
    --query 'StepIds[0]' --output text)
  echo "        Step ID: $STEP_ID"
  wait_con_timer "step" \
    "aws emr describe-step --cluster-id $CLUSTER_ID --step-id $STEP_ID --region $REGION --query Step.Status.State --output text" \
    '^COMPLETED$' \
    '^(FAILED|CANCELLED|INTERRUPTED)$' || true
}

# ── Crear cluster EMR con Hadoop + Hive ───────────────────────────────────────
echo ""
echo "[ 3/4 ] Creando cluster EMR (1 master + $CORE_COUNT core $INSTANCE_TYPE)..."
echo "        Aplicaciones: Hadoop + Hive"
echo "        (puede tardar 5-10 min)"

# Roles explícitos en UN solo --ec2-attributes (no mezclar con --use-default-roles,
# que inyecta su propio --ec2-attributes y colisiona cuando añadimos KeyName).
EC2_ATTRS="InstanceProfile=EMR_EC2_DefaultRole"
if [[ -n "$KEY_PAIR" ]]; then
  EC2_ATTRS="$EC2_ATTRS,KeyName=$KEY_PAIR"
  echo "        Key pair : $KEY_PAIR"
fi

CLUSTER_ID=$(aws emr create-cluster \
  --name "TaxiTrips-Hive-taxiscope" \
  --release-label emr-7.0.0 \
  --applications Name=Hadoop Name=Hive \
  --instance-groups \
    "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$INSTANCE_TYPE" \
    "InstanceGroupType=CORE,InstanceCount=$CORE_COUNT,InstanceType=$INSTANCE_TYPE" \
  --service-role EMR_DefaultRole \
  --ec2-attributes "$EC2_ATTRS" \
  --region "$REGION" \
  --log-uri "s3://$BUCKET/logs/" \
  --no-auto-terminate \
  --enable-debugging \
  --query 'ClusterId' \
  --output text)

echo "        Cluster ID: $CLUSTER_ID"

# Guardar estado YA: si CloudShell se cae, el cluster sigue vivo
# (--no-auto-terminate) y puedes reconectar / limpiar con estos IDs.
{
  echo "CLUSTER_ID=$CLUSTER_ID"
  echo "BUCKET=$BUCKET"
  echo "REGION=$REGION"
} > "$ROOT_DIR/taxiscope/.emr_state"

echo "        (IDs guardados en taxiscope/.emr_state)"
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

# ── Step de setup (tabla externa sobre Parquet) ───────────────────────────────
echo ""
echo "[ 4/4 ] Preparando tablas externas (taxi_raw_a / taxi_raw_b) con Hive..."
run_hive_step "Setup-Taxi-Hive" "s3://$BUCKET/hql/setup.hql" \
  "INA=s3://$BUCKET/raw_a/" "INB=s3://$BUCKET/raw_b/"
T_SETUP="$LAST_ELAPSED"
echo "        Duración del step (setup tabla): $T_SETUP"

STATUS=$(aws emr describe-step \
  --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" --region "$REGION" \
  --query 'Step.Status.State' --output text)

if [[ "$STATUS" != "COMPLETED" ]]; then
  echo ""
  echo "  El step de setup FALLÓ ($STATUS). Terminando cluster..."
  aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION" 2>/dev/null || true
  echo "  Ver logs:"
  echo "  aws s3 cp s3://$BUCKET/logs/$CLUSTER_ID/steps/$STEP_ID/stderr.gz - | gunzip -c"
  exit 1
fi

# ── Particionamiento opcional como step (medido) ──────────────────────────────
T_PART="(no ejecutado)"
if [[ "$DO_PARTITION" -eq 1 ]]; then
  echo ""
  echo "  Particionando datos hacia HDFS (taxi_part) ..."
  run_hive_step "Particionar-Taxi" "s3://$BUCKET/hql/partition.hql"
  T_PART="$LAST_ELAPSED"
  PSTATUS=$(aws emr describe-step \
    --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" --region "$REGION" \
    --query 'Step.Status.State' --output text)
  if [[ "$PSTATUS" != "COMPLETED" ]]; then
    echo "  ⚠ El particionamiento falló ($PSTATUS). Revísalo en la sesión interactiva."
    echo "    aws s3 cp s3://$BUCKET/logs/$CLUSTER_ID/steps/$STEP_ID/stderr.gz - | gunzip -c"
    T_PART="FALLÓ ($PSTATUS)"
  fi
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ENTORNO LISTO                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Tablas externas: taxi_raw_a + taxi_raw_b  (Parquet crudo en S3)"
if [[ "$DO_PARTITION" -eq 1 ]]; then
echo "  Tabla HDFS     : taxi_part  (unificada y particionada por anio/mes)"
fi
echo "  Logs en       : s3://$BUCKET/logs/"
echo ""
echo "  ── Tiempos ──────────────────────────────────────"
echo "    Aprovisionar cluster : $T_CLUSTER"
echo "    Setup tabla (step)   : $T_SETUP"
echo "    Particionamiento     : $T_PART"
echo ""
echo "  ── Abrir sesión Hive (requiere --key-pair en este paso) ──"
echo "  bash taxiscope/scripts/hive_shell.sh"
echo ""
if [[ "$DO_PARTITION" -ne 1 ]]; then
echo "  Dentro de Hive, particiona primero (mide Time taken) — taxiscope/hql/partition.hql"
echo "  y luego corre las consultas analíticas — taxiscope/hql/queries.hql"
else
echo "  Dentro de Hive, corre las consultas analíticas — taxiscope/hql/queries.hql"
fi
echo ""
echo "  ── Terminar cluster (evitar costos) ─────────────"
echo "  aws emr terminate-clusters --cluster-ids $CLUSTER_ID"
