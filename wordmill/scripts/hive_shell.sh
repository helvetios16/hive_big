#!/bin/bash
# =============================================================================
# hive_shell.sh — Abre sesión Hive interactiva en el master via EC2 Instance Connect
#
# Uso:
#   bash wordmill/scripts/hive_shell.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/wordmill/.emr_state"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: no se encontró wordmill/.emr_state"
  echo "Ejecuta run_hive.sh primero."
  exit 1
fi
source "$STATE_FILE"

# ── Verificar cluster activo ──────────────────────────────────────────────────
STATUS=$(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Status.State' --output text)

if [[ "$STATUS" != "WAITING" && "$STATUS" != "RUNNING" ]]; then
  echo "ERROR: cluster $CLUSTER_ID no está activo (estado: $STATUS)"
  exit 1
fi

# ── Obtener datos del master ──────────────────────────────────────────────────
echo "Obteniendo datos del master..."

# DNS y AZ del master en una sola consulta a EMR (sin ec2:DescribeInstances)
read -r MASTER_DNS AZ < <(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.[MasterPublicDnsName, Ec2InstanceAttributes.Ec2AvailabilityZone]' \
  --output text)

MASTER_ID=$(aws emr list-instances \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --instance-group-type MASTER \
  --query 'Instances[0].Ec2InstanceId' --output text)

echo "  Master DNS : $MASTER_DNS"
echo "  Instance   : $MASTER_ID  ($AZ)"

# ── Abrir puerto 22 para la IP actual ────────────────────────────────────────
# tr -d quita el newline que curl añade al final
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
SG=$(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Ec2InstanceAttributes.EmrManagedMasterSecurityGroup' --output text)

echo "  Abriendo puerto 22 para $MY_IP en $SG..."
if aws ec2 authorize-security-group-ingress \
     --region "$REGION" \
     --group-id "$SG" \
     --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null; then
  echo "  ✓ Regla añadida."
else
  echo "  (regla ya existía, continuando)"
fi

# ── Generar key temporal ──────────────────────────────────────────────────────
TMP_KEY="/tmp/emr_hive_$$"
rm -f "$TMP_KEY" "${TMP_KEY}.pub"

# Trap: limpiar key aunque el script falle o el usuario haga Ctrl+C
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub"' EXIT

ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q
echo "  Key temporal generada."

# ── Empujar key con EC2 Instance Connect (válida 60 segundos) ─────────────────
aws ec2-instance-connect send-ssh-public-key \
  --region "$REGION" \
  --instance-id "$MASTER_ID" \
  --availability-zone "$AZ" \
  --instance-os-user hadoop \
  --ssh-public-key "file://${TMP_KEY}.pub" \
  --output text --query 'Success' > /dev/null

echo ""
echo "  Conectando... Hive puede tardar ~20s en arrancar."
echo "  Escribe 'exit;' para salir de Hive."
echo ""

# ── SSH al master y lanzar Hive ───────────────────────────────────────────────
ssh -i "$TMP_KEY" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 \
    -o ConnectTimeout=15 \
    -t hadoop@"$MASTER_DNS" \
    "hive" || true   # 'true' evita que set -e corte el script si Hive sale con código != 0
