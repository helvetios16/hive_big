#!/bin/bash
# =============================================================================
# launch_test_instance.sh — Lanza UNA instancia EC2 mínima de prueba
#
# Objetivo: comprobar que tu AWS CLI + credenciales de AWS Academy Learner Lab
# pueden aprovisionar cómputo. Usa Amazon Linux 2023, t2.micro, sin key pair
# (solo lanza y termina; no hace falta SSH para la prueba).
#
# Uso:
#   bash sandbox/launch_test_instance.sh
#   bash sandbox/launch_test_instance.sh --type t3.micro --region us-east-1
#
# Después, para borrarla:
#   bash sandbox/terminate_test_instance.sh
# =============================================================================
set -euo pipefail

REGION="us-east-1"
INSTANCE_TYPE="t2.micro"
NAME_TAG="test-academy-sandbox"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/sandbox/.ec2_state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)   INSTANCE_TYPE="$2"; shift 2 ;;
    --region) REGION="$2";        shift 2 ;;
    *) shift ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   EC2 — Instancia de prueba (sandbox)            ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Región : $REGION"
echo "  Tipo   : $INSTANCE_TYPE"
echo "  Tag    : Name=$NAME_TAG"
echo ""

# ── Verificar credenciales ────────────────────────────────────────────────────
aws sts get-caller-identity --query 'Arn' --output text >/dev/null || {
  echo "ERROR: AWS CLI no configurado o credenciales expiradas."
  echo "Repega access key / secret / session token desde 'AWS Details' del lab."
  exit 1
}

# ── Evitar duplicados: ¿ya hay una instancia de prueba viva? ──────────────────
EXISTING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$NAME_TAG" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$EXISTING" ]]; then
  echo "Ya existe una instancia de prueba viva: $EXISTING"
  echo "Termínala primero:  bash sandbox/terminate_test_instance.sh"
  exit 1
fi

# ── Resolver la AMI más reciente de Amazon Linux 2023 (vía SSM público) ───────
echo "[ 1/3 ] Resolviendo AMI de Amazon Linux 2023..."
AMI_ID=$(aws ssm get-parameters \
  --region "$REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
echo "        AMI: $AMI_ID"

# ── Lanzar la instancia ───────────────────────────────────────────────────────
echo ""
echo "[ 2/3 ] Lanzando instancia $INSTANCE_TYPE..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --count 1 \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "        Instance ID: $INSTANCE_ID"

# Guardar estado YA, por si se corta la terminal: terminate lo leerá de aquí.
{
  echo "INSTANCE_ID=$INSTANCE_ID"
  echo "REGION=$REGION"
} > "$STATE_FILE"
echo "        (ID guardado en sandbox/.ec2_state)"

# ── Esperar a 'running' y mostrar datos ───────────────────────────────────────
echo ""
echo "[ 3/3 ] Esperando estado 'running'..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

read -r STATE PUBLIC_IP <<<"$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
  --output text)"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   INSTANCIA LISTA                                ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Instance ID : $INSTANCE_ID"
echo "  Estado      : $STATE"
echo "  IP pública  : ${PUBLIC_IP:-(sin IP pública)}"
echo ""
echo "  ⚠ Recuerda terminarla para no gastar saldo del lab:"
echo "  bash sandbox/terminate_test_instance.sh"
echo ""
