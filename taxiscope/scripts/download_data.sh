#!/bin/bash
# =============================================================================
# download_data.sh — Descarga el dataset NYC TLC Yellow Taxi (Parquet) y lo
#                    sube a S3 (modo normal) o lo guarda en disco (--local-dir,
#                    para probar la descarga / inspeccionar esquemas).
#
# Fuente: https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page
#         (los .parquet se sirven desde la CDN de CloudFront del TLC)
#
# Uso (S3, para EMR):
#   bash taxiscope/scripts/download_data.sh                  # bucket y años por defecto
#   bash taxiscope/scripts/download_data.sh --bucket <b> --years 2020-2025
#
# Uso (local, para probar en esta máquina):
#   bash taxiscope/scripts/download_data.sh --local-dir /ruta
#   bash taxiscope/scripts/download_data.sh --local-dir /ruta --year 2024 --months "1 2 3"
#
# Flags:
#   --bucket <b>     bucket S3 destino (modo S3)             (default mi-hive-taxi)
#   --local-dir <d>  carpeta local destino (modo local; ignora S3)
#   --years <r>      rango "2020-2025" o lista "2020 2021"  (tiene prioridad)
#   --year <y>       un solo año
#   --months "..."   meses entre comillas                   (default los 12)
#   --type <t>       yellow | green                         (default yellow)
#   --region <r>     región AWS                             (default us-east-1)
#
# Defaults: bucket mi-hive-taxi, años 2020-2025, los 12 meses (~3.4 GB).
# =============================================================================
set -euo pipefail

BUCKET="mi-hive-taxi"
LOCAL_DIR=""
YEARS=""
YEAR=""
MONTHS="1 2 3 4 5 6 7 8 9 10 11 12"
TYPE="yellow"
REGION="us-east-1"
BASE_URL="https://d37ci6vzurychx.cloudfront.net/trip-data"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)    BUCKET="$2";    shift 2 ;;
    --local-dir) LOCAL_DIR="$2"; shift 2 ;;
    --years)     YEARS="$2";     shift 2 ;;
    --year)      YEAR="$2";      shift 2 ;;
    --months)    MONTHS="$2";    shift 2 ;;
    --type)      TYPE="$2";      shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    *) shift ;;
  esac
done

# ── Resolver lista de años ────────────────────────────────────────────────────
if [[ -n "$YEARS" ]]; then
  if [[ "$YEARS" == *-* ]]; then
    YEARS=$(seq "${YEARS%-*}" "${YEARS#*-}")   # "2020-2025" → 2020 2021 ... 2025
  fi
elif [[ -n "$YEAR" ]]; then
  YEARS="$YEAR"
else
  YEARS="2020 2021 2022 2023 2024 2025"   # default: histórico completo
fi

# ── Era de esquema del archivo (el Parquet del TLC cambió de tipos) ───────────
#   Era A : 2020-01 .. 2023-01  (passenger_count DOUBLE, ids BIGINT)
#   Era B : 2023-02 ..          (passenger_count BIGINT, ids INT)
# Se enruta a prefijos distintos (raw_a/ raw_b/) para que cada tabla externa
# de Hive lea tipos homogéneos. Solo aplica a yellow/green con este histórico.
era_de() {
  local y="$1" m="$2"
  if (( y < 2023 )) || { (( y == 2023 )) && (( 10#$m == 1 )); }; then
    echo "a"
  else
    echo "b"
  fi
}

# ── Determinar modo (local vs S3) ─────────────────────────────────────────────
MODE="s3"
if [[ -n "$LOCAL_DIR" ]]; then
  MODE="local"
  mkdir -p "$LOCAL_DIR"
elif [[ -z "$BUCKET" ]]; then
  echo "ERROR: indica --bucket <nombre> (modo S3) o --local-dir <ruta> (modo local)"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   NYC TLC Taxi — descarga de Parquet             ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Tipo    : $TYPE tripdata"
echo "  Años    : $(echo $YEARS | tr '\n' ' ')"
echo "  Meses   : $MONTHS"
if [[ "$MODE" == "local" ]]; then
  echo "  Destino : $LOCAL_DIR/raw_{a,b}/  (LOCAL)"
else
  echo "  Destino : s3://$BUCKET/raw_{a,b}/  (S3)"
fi
echo ""

# ── Crear bucket si no existe (solo modo S3) ──────────────────────────────────
if [[ "$MODE" == "s3" ]] && ! aws s3 ls "s3://$BUCKET" >/dev/null 2>&1; then
  echo "Creando bucket s3://$BUCKET ..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "  ✓ Bucket creado."
fi

# Dir temporal solo para modo S3 (descarga → sube → borra)
if [[ "$MODE" == "s3" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
fi

TOTAL=0
FALLOS=0
for Y in $YEARS; do
  for M in $MONTHS; do
    MM=$(printf "%02d" "$M")
    FILE="${TYPE}_tripdata_${Y}-${MM}.parquet"
    URL="$BASE_URL/$FILE"
    ERA=$(era_de "$Y" "$MM")          # a | b → prefijo raw_a/ raw_b/

    if [[ "$MODE" == "local" ]]; then
      mkdir -p "$LOCAL_DIR/raw_$ERA"
      DEST="$LOCAL_DIR/raw_$ERA/$FILE"
      if [[ -f "$DEST" ]]; then
        echo "  = raw_$ERA/$FILE ya existe, se omite."
        TOTAL=$((TOTAL + 1)); continue
      fi
      echo "── $FILE  (era $ERA) ──"
      if curl -fSL --retry 5 --retry-all-errors --retry-delay 5 -o "$DEST" "$URL" 2>/dev/null; then
        echo "  ✓ $(du -h "$DEST" | cut -f1)  →  $DEST"
        TOTAL=$((TOTAL + 1))
      else
        echo "  ⚠ falló (404 sin publicar, o throttling de la CDN). Re-ejecuta el comando."
        rm -f "$DEST"; FALLOS=$((FALLOS + 1))
      fi
    else
      echo "── $FILE  (era $ERA) ──"
      # Idempotente: si ya está en S3, no lo vuelve a bajar (re-ejecuta sin re-throttle)
      if aws s3 ls "s3://$BUCKET/raw_$ERA/$FILE" >/dev/null 2>&1; then
        echo "  = ya está en s3://$BUCKET/raw_$ERA/, se omite."
        TOTAL=$((TOTAL + 1)); continue
      fi
      LOCAL="$TMP_DIR/$FILE"
      # --retry-all-errors + delay: reintenta también ante 403/429 (throttling CDN)
      if curl -fSL --retry 5 --retry-all-errors --retry-delay 5 -o "$LOCAL" "$URL" 2>/dev/null; then
        aws s3 cp "$LOCAL" "s3://$BUCKET/raw_$ERA/$FILE"
        rm -f "$LOCAL"
        echo "  ✓ s3://$BUCKET/raw_$ERA/$FILE"
        TOTAL=$((TOTAL + 1))
      else
        echo "  ⚠ falló (404 sin publicar, o throttling de la CDN). Re-ejecuta el comando."
        FALLOS=$((FALLOS + 1))
      fi
    fi
  done
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Descarga terminada                             ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Archivos OK     : $TOTAL"
echo "  Omitidos        : $FALLOS"
if [[ "$MODE" == "local" ]]; then
  echo "  Ubicación       : $LOCAL_DIR"
else
  echo "  Ubicación       : s3://$BUCKET/raw_a/ y s3://$BUCKET/raw_b/"
  echo ""
  echo "  Siguiente paso:"
  echo "    bash taxiscope/scripts/run_hive.sh --bucket $BUCKET --key-pair <kp> --partition"
fi

if [[ "$TOTAL" -eq 0 ]]; then
  echo ""
  echo "ERROR: no se descargó ningún archivo. Revisa --years/--months/--type."
  exit 1
fi
