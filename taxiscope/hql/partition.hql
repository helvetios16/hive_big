-- ============================================================
-- Particionamiento  |  taxiscope — Actividad 4 (NYC Taxi Trips)
--
-- Crea una tabla GESTIONADA (managed) particionada por año y mes y carga
-- en ella los datos de AMBAS eras (taxi_raw_a + taxi_raw_b) UNIFICANDO los
-- tipos con CAST. La tabla gestionada vive en el warehouse de Hive sobre
-- HDFS (hdfs:///user/hive/warehouse/taxi_part) → esto es "cargar los datos
-- en HDFS". Particionar por (anio, mes) permite partition pruning.
--
-- Tipos unificados: passenger_count/ratecodeid -> DOUBLE,
--                   vendorid/pulocationid/dolocationid -> BIGINT.
-- ============================================================

-- Particionado dinámico (deriva la partición del timestamp)
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
-- margen de sobra para ~72 particiones (6 años x 12 meses)
SET hive.exec.max.dynamic.partitions = 2000;
SET hive.exec.max.dynamic.partitions.pernode = 1000;

DROP TABLE IF EXISTS taxi_part;

CREATE TABLE taxi_part (
    vendorid               BIGINT,
    tpep_pickup_datetime   TIMESTAMP,
    tpep_dropoff_datetime  TIMESTAMP,
    passenger_count        DOUBLE,
    trip_distance          DOUBLE,
    ratecodeid             DOUBLE,
    store_and_fwd_flag     STRING,
    pulocationid           BIGINT,
    dolocationid           BIGINT,
    payment_type           BIGINT,
    fare_amount            DOUBLE,
    extra                  DOUBLE,
    mta_tax                DOUBLE,
    tip_amount             DOUBLE,
    tolls_amount           DOUBLE,
    improvement_surcharge  DOUBLE,
    total_amount           DOUBLE,
    congestion_surcharge   DOUBLE
)
PARTITIONED BY (anio INT, mes INT)
STORED AS PARQUET;

-- ── Carga era A (tipos ya compatibles con la tabla unificada) ─────────
INSERT INTO TABLE taxi_part PARTITION (anio, mes)
SELECT
    vendorid, tpep_pickup_datetime, tpep_dropoff_datetime,
    passenger_count, trip_distance, ratecodeid, store_and_fwd_flag,
    pulocationid, dolocationid, payment_type, fare_amount, extra,
    mta_tax, tip_amount, tolls_amount, improvement_surcharge,
    total_amount, congestion_surcharge,
    YEAR(tpep_pickup_datetime)  AS anio,
    MONTH(tpep_pickup_datetime) AS mes
FROM taxi_raw_a
WHERE tpep_pickup_datetime IS NOT NULL
  AND YEAR(tpep_pickup_datetime) BETWEEN 2020 AND 2025;

-- ── Carga era B (CAST de ids a BIGINT y counts a DOUBLE) ──────────────
INSERT INTO TABLE taxi_part PARTITION (anio, mes)
SELECT
    CAST(vendorid AS BIGINT), tpep_pickup_datetime, tpep_dropoff_datetime,
    CAST(passenger_count AS DOUBLE), trip_distance,
    CAST(ratecodeid AS DOUBLE), store_and_fwd_flag,
    CAST(pulocationid AS BIGINT), CAST(dolocationid AS BIGINT),
    payment_type, fare_amount, extra, mta_tax, tip_amount, tolls_amount,
    improvement_surcharge, total_amount, congestion_surcharge,
    YEAR(tpep_pickup_datetime)  AS anio,
    MONTH(tpep_pickup_datetime) AS mes
FROM taxi_raw_b
WHERE tpep_pickup_datetime IS NOT NULL
  AND YEAR(tpep_pickup_datetime) BETWEEN 2020 AND 2025;

-- Verificar las particiones creadas
SHOW PARTITIONS taxi_part;
