# ============================================================
# taxiscope — Análisis distribuido de NYC Taxi Trips en Hive (Actividad 4)
# Dataset: https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page
# Formato: Parquet (Yellow Taxi). Hive lo lee de forma nativa.
# ============================================================

# 1. Descargar el dataset y subirlo a S3 (crea el bucket si no existe).
#    DEFAULTS: --bucket mi-hive-taxi  y  --years 2020-2025 (12 meses c/u).
#    OJO: el esquema Parquet del TLC cambió en feb-2023, por eso el script
#    enruta los archivos a dos prefijos por "era" de esquema:
#       raw_a/  = 2020-01 .. 2023-01   (passenger_count DOUBLE, ids BIGINT)
#       raw_b/  = 2023-02 ..           (passenger_count BIGINT, ids INT)
#    Hive lee cada era con su propia tabla externa y luego las unifica.
#
#    Histórico completo 2020-2025 a s3://mi-hive-taxi (~3.4 GB, ~223M viajes):
bash taxiscope/scripts/download_data.sh
#    Subconjunto más ligero para probar (un año, 3 meses):
# bash taxiscope/scripts/download_data.sh --year 2024 --months "1 2 3"
#    Otro bucket o rango:
# bash taxiscope/scripts/download_data.sh --bucket otro-bucket --years 2024-2025
#    Probar SOLO la descarga en tu máquina (sin S3):
# bash taxiscope/scripts/download_data.sh --local-dir /ruta/local

# 2. (una vez) Key pair para la sesión Hive interactiva — si aún no tienes
aws ec2 create-key-pair --key-name taxi-kp \
  --query KeyMaterial --output text > ~/taxi-kp.pem
chmod 600 ~/taxi-kp.pem

# 3. Cluster EMR + tabla externa + (opcional) particionamiento.
#    --partition ejecuta el particionamiento como step y MIDE su tiempo.
#    Sin --partition, lo haces tú en la sesión interactiva (paso 5) para
#    cronometrarlo. El script sondea cada 30s con timer [mm:ss] y al final
#    imprime los tiempos por etapa (aprovisionar / setup / particionar).
bash taxiscope/scripts/run_hive.sh \
  --bucket mi-hive-taxi \
  --key-pair taxi-kp \
  --core-count 2 \
  --partition

# 4. Sesión Hive interactiva
bash taxiscope/scripts/hive_shell.sh

# 5. Dentro de Hive:
#    a) Si NO usaste --partition, crea aquí la tabla particionada y MIDE
#       el "Time taken" (= cargar los datos en HDFS, particionados).
#       Pega el contenido de taxiscope/hql/partition.hql: crea taxi_part
#       (unificada) PARTITIONED BY (anio, mes) y hace dos INSERT INTO desde
#       taxi_raw_a y taxi_raw_b (era B con CAST). Termina en SHOW PARTITIONS.
#
#    b) Consultas analíticas (cada una imprime "Time taken: N seconds")
#       — referencia completa en taxiscope/hql/queries.hql:
#
#       -- 1. Total de viajes
#       SELECT COUNT(*) FROM taxi_part;
#
#       -- 2. Promedio de distancia
#       SELECT ROUND(AVG(trip_distance),3) FROM taxi_part WHERE trip_distance > 0;
#
#       -- 3. Horas con mayor tráfico
#       SELECT HOUR(tpep_pickup_datetime) AS hora, COUNT(*) AS viajes
#       FROM taxi_part GROUP BY HOUR(tpep_pickup_datetime) ORDER BY viajes DESC;
#
#       -- 4. Métodos de pago
#       SELECT payment_type, COUNT(*) FROM taxi_part GROUP BY payment_type ORDER BY 2 DESC;
#
#       -- 5. Top 10 viajes más costosos
#       SELECT tpep_pickup_datetime, trip_distance, total_amount
#       FROM taxi_part WHERE total_amount > 0 ORDER BY total_amount DESC LIMIT 10;
#
#       -- 6. Consulta con particiones (partition pruning)
#       SELECT anio, mes, COUNT(*) FROM taxi_part
#       WHERE anio=2024 AND mes IN (1,2,3) GROUP BY anio, mes ORDER BY anio, mes;
#
#       exit;

# 6. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-3>

# 7. Limpieza total (cluster + bucket + locales)
bash taxiscope/scripts/cleanup.sh
