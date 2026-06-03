-- ============================================================
-- Setup de entrada  |  taxiscope — Actividad 4 (NYC Taxi Trips)
--
-- El esquema Parquet del TLC CAMBIÓ a mitad del histórico, así que NO se
-- puede leer todo con una sola tabla de tipos fijos sin que Hive falle:
--
--   Era A (2020-01 .. 2023-01):  passenger_count/RatecodeID = DOUBLE,
--                                VendorID/PU/DOLocationID    = BIGINT (int64)
--   Era B (2023-02 ..      ):    passenger_count/RatecodeID = BIGINT (int64),
--                                VendorID/PU/DOLocationID    = INT    (int32)
--
-- Solución robusta: UNA tabla externa por era, declarando en cada una los
-- tipos EXACTOS del Parquet de esa era (sin promociones que puedan fallar).
-- Luego partition.hql las unifica con CAST en una sola tabla particionada.
--
-- Los archivos se suben a S3 en prefijos separados por era:
--   s3://bucket/raw_a/  (era A)   y   s3://bucket/raw_b/  (era B)
--
-- Se omiten airport_fee / cbd_congestion_fee (cambian de nombre/tipo entre
-- años y ninguna consulta de la actividad las usa).
-- ============================================================

-- ── Era A : 2020-01 .. 2023-01  (DOUBLE counts, BIGINT ids) ───────────
DROP TABLE IF EXISTS taxi_raw_a;
CREATE EXTERNAL TABLE taxi_raw_a (
    vendorid               BIGINT,
    tpep_pickup_datetime   BIGINT,   -- Parquet int64 (microsegundos); Hive no lo
    tpep_dropoff_datetime  BIGINT,   -- lee como TIMESTAMP, se convierte en partition.hql
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
STORED AS PARQUET
LOCATION '${hivevar:INA}';

-- ── Era B : 2023-02 ..  (BIGINT counts, INT ids) ──────────────────────
DROP TABLE IF EXISTS taxi_raw_b;
CREATE EXTERNAL TABLE taxi_raw_b (
    vendorid               INT,
    tpep_pickup_datetime   BIGINT,   -- Parquet int64 (microsegundos); Hive no lo
    tpep_dropoff_datetime  BIGINT,   -- lee como TIMESTAMP, se convierte en partition.hql
    passenger_count        BIGINT,
    trip_distance          DOUBLE,
    ratecodeid             BIGINT,
    store_and_fwd_flag     STRING,
    pulocationid           INT,
    dolocationid           INT,
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
STORED AS PARQUET
LOCATION '${hivevar:INB}';
