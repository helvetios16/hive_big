#!/bin/bash
# =============================================================================
# terminate_test_instance.sh — Termina la instancia EC2 de prueba
#
# Lee el ID desde sandbox/.ec2_state (lo escribe launch_test_instance.sh).
# Si no hay estado, la busca por su tag Name=test-academy-sandbox.
#
# Uso:
#   bash sandbox/terminate_test_instance.sh
#   bash sandbox/terminate_test_instance.sh --instance-id i-0123... --region us-east-1
# =============================================================================
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=""
NAME_TAG="test-academy-sandbox"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/sandbox/.ec2_state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    *) shift ;;
  esac
done

# ── Resolver el ID: 1º flag, 2º archivo de estado, 3º búsqueda por tag ────────
if [[ -z "$INSTANCE_ID" && -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi
if [[ -z "$INSTANCE_ID" ]]; then
  echo "No hay ID en flag ni en estado; buscando por tag Name=$NAME_TAG..."
  INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME_TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
fi

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "No se encontró ninguna instancia de prueba viva. Nada que terminar."
  rm -f "$STATE_FILE"
  exit 0
fi

echo ""
echo "Terminando instancia(s): $INSTANCE_ID  (región $REGION)"
aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_ID \
  --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text

echo "Esperando estado 'terminated'..."
aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_ID

rm -f "$STATE_FILE"
echo ""
echo "✓ Instancia(s) terminada(s) y estado limpiado."
echo ""
