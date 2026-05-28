#!/bin/bash
# =============================================================================
# hive_shell.sh — Abre sesión Hive interactiva en el master via EC2 Instance Connect
#
# No requiere haber configurado un key pair al crear el cluster.
# Genera una key temporal, la empuja al master (válida 60s) y conecta.
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

MASTER_DNS=$(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.MasterPublicDnsName' --output text)

MASTER_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:aws:elasticmapreduce/job-flow-id,Values=$CLUSTER_ID" \
    "Name=tag:aws:elasticmapreduce/instance-group-role,Values=MASTER" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

AZ=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$MASTER_ID" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)

echo "  Master DNS : $MASTER_DNS"
echo "  Instance   : $MASTER_ID  ($AZ)"

# ── Generar key temporal ──────────────────────────────────────────────────────
TMP_KEY=$(mktemp /tmp/emr_tmp_key_XXXX)
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q
echo "  Key temporal generada."

# ── Empujar key con EC2 Instance Connect (válida 60 segundos) ─────────────────
aws ec2-instance-connect send-ssh-public-key \
  --region "$REGION" \
  --instance-id "$MASTER_ID" \
  --availability-zone "$AZ" \
  --instance-os-user hadoop \
  --ssh-public-key "file://${TMP_KEY}.pub"

echo ""
echo "  Key enviada — tienes 60 segundos para conectar."
echo "  Abriendo Hive... (escribe 'exit;' para salir)"
echo ""

# ── Conectar y lanzar Hive ────────────────────────────────────────────────────
ssh -i "$TMP_KEY" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 \
    -t hadoop@"$MASTER_DNS" \
    "hive"

# ── Limpiar key temporal ──────────────────────────────────────────────────────
rm -f "$TMP_KEY" "${TMP_KEY}.pub"
