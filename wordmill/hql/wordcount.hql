-- ============================================================
-- WordCount en HiveQL  |  wordmill — Actividad 1
--
-- Flujo:
--   1. Tabla externa sobre texto en S3 / HDFS
--   2. Tokenización con LATERAL VIEW EXPLODE + SPLIT
--   3. GROUP BY distribuido
--   4. COUNT(*) por palabra
--   5. Preview top 20
-- ============================================================

-- Variables esperadas (pasadas desde run_hive.sh):
--   ${hivevar:INPUT}   s3://bucket/input/
--   ${hivevar:OUTPUT}  s3://bucket/output/

-- ── Configuración ─────────────────────────────────────────────
SET hive.exec.compress.output=false;
SET hive.exec.dynamic.partition.mode=nonstrict;

-- ── 1. Tabla de entrada (apunta al texto en S3) ───────────────
DROP TABLE IF EXISTS wm_input;

CREATE EXTERNAL TABLE wm_input (
    line STRING
)
STORED AS TEXTFILE
LOCATION '${hivevar:INPUT}';

-- ── 2 + 3 + 4. Tokenizar → GROUP BY → COUNT distribuido ───────
--   SPLIT(LOWER(line), '[^a-z]+')  →  array de tokens limpios
--   LATERAL VIEW EXPLODE(...)       →  una fila por token
--   GROUP BY word + COUNT(*)        →  conteo distribuido
DROP TABLE IF EXISTS wm_wordcount;

CREATE TABLE wm_wordcount (
    word  STRING,
    total BIGINT
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION '${hivevar:OUTPUT}';

INSERT INTO TABLE wm_wordcount
SELECT
    word,
    COUNT(*) AS total
FROM wm_input
LATERAL VIEW EXPLODE(
    SPLIT(LOWER(line), '[^a-z]+')
) tokens AS word
WHERE LENGTH(word) > 1
GROUP BY word;

-- ── 5. Preview: top 20 palabras más frecuentes ────────────────
SELECT
    word,
    total
FROM wm_wordcount
ORDER BY total DESC
LIMIT 20;
