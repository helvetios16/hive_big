#!/bin/bash
# =============================================================================
# connect_test_instance.sh — SSH a la EC2 de prueba vía EC2 Instance Connect
#
# Mismo patrón que taxiscope/hive_shell.sh, pero contra la instancia del
# sandbox y usuario ec2-user (Amazon Linux 2023). NO necesitas key pair: el
# AWS CLI inyecta una clave temporal (válida 60s) y abre el puerto 22 solo
# para tu IP actual.
#
# Pre-requisito: haber lanzado la instancia con launch_test_instance.sh.
#
# Uso:
#   bash sandbox/connect_test_instance.sh
#   bash sandbox/connect_test_instance.sh --instance-id i-0123... --region us-east-1
# =============================================================================
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=""
OS_USER="ec2-user"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/sandbox/.ec2_state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    *) shift ;;
  esac
done

# ── Resolver el ID: flag > archivo de estado ──────────────────────────────────
if [[ -z "$INSTANCE_ID" && -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "ERROR: no hay instancia. Lánzala primero:"
  echo "  bash sandbox/launch_test_instance.sh"
  exit 1
fi

# ── Datos de la instancia (estado, DNS/IP, AZ, security group) ────────────────
echo "Obteniendo datos de la instancia $INSTANCE_ID..."
read -r STATE PUB_DNS PUB_IP AZ SG < <(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicDnsName,PublicIpAddress,Placement.AvailabilityZone,SecurityGroups[0].GroupId]' \
  --output text)

if [[ "$STATE" != "running" ]]; then
  echo "ERROR: la instancia no está 'running' (estado: $STATE)."
  exit 1
fi

# Preferir DNS público; si está vacío (VPC sin DNS hostnames), usar la IP.
HOST="$PUB_DNS"
[[ -z "$HOST" || "$HOST" == "None" ]] && HOST="$PUB_IP"
if [[ -z "$HOST" || "$HOST" == "None" ]]; then
  echo "ERROR: la instancia no tiene DNS/IP pública para SSH."
  exit 1
fi
echo "  Host : $HOST"
echo "  AZ   : $AZ   SG: $SG"

# ── Abrir puerto 22 para tu IP actual ─────────────────────────────────────────
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
echo "  Abriendo puerto 22 para $MY_IP en $SG..."
if aws ec2 authorize-security-group-ingress \
     --region "$REGION" --group-id "$SG" \
     --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null; then
  echo "  ✓ Regla añadida."
else
  echo "  (regla ya existía, continuando)"
fi

# ── Clave temporal (se borra al salir, aunque falle o hagas Ctrl+C) ───────────
TMP_KEY="/tmp/sandbox_eic_$$"
rm -f "$TMP_KEY" "${TMP_KEY}.pub"
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub"' EXIT
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q
echo "  Clave temporal generada."

# ── Empujar la clave con EC2 Instance Connect (válida 60s) ────────────────────
aws ec2-instance-connect send-ssh-public-key \
  --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --availability-zone "$AZ" \
  --instance-os-user "$OS_USER" \
  --ssh-public-key "file://${TMP_KEY}.pub" \
  --output text --query 'Success' > /dev/null

echo ""
echo "  Conectando como $OS_USER@$HOST ..."
echo "  (si recién lanzaste, puede tardar ~30s en aceptar SSH)"
echo "  Escribe 'exit' para salir."
echo ""

# ── SSH a la instancia (shell interactiva) ────────────────────────────────────
ssh -i "$TMP_KEY" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 \
    -o ConnectTimeout=15 \
    -t "$OS_USER@$HOST" || true   # 'true': set -e no corta si la shell sale != 0
