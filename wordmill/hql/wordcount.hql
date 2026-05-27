-- ============================================================
-- WordCount en HiveQL  |  wordmill — Actividad 1
--
-- Flujo:
--   1. Tabla externa sobre el texto en S3 / HDFS
--   2. Separación de palabras con LATERAL VIEW EXPLODE + SPLIT
--   3. GROUP BY distribuido + COUNT(*)
--   4. Consultas analíticas sobre la tabla resultante
-- ============================================================

SET hive.exec.compress.output=false;

-- ── 1. Tabla de entrada ───────────────────────────────────────
DROP TABLE IF EXISTS wm_input;

CREATE EXTERNAL TABLE wm_input (
    line STRING
)
STORED AS TEXTFILE
LOCATION '${hivevar:INPUT}';

-- ── 2 + 3. Separar palabras → GROUP BY → COUNT distribuido ───
--   CTAS: crea la tabla y ejecuta el WordCount en un solo paso
DROP TABLE IF EXISTS wm_wordcount;

CREATE TABLE wm_wordcount AS
SELECT
    word,
    COUNT(*) AS total
FROM wm_input
LATERAL VIEW EXPLODE(
    SPLIT(LOWER(line), '[^a-z]+')
) tokens AS word
WHERE LENGTH(word) > 1
GROUP BY word;

-- ── 4. Consultas analíticas sobre la tabla ───────────────────

-- 4a. Top 20 palabras más frecuentes
SELECT word, total
FROM wm_wordcount
ORDER BY total DESC
LIMIT 20;

-- 4b. Total de palabras únicas en el corpus
SELECT COUNT(*) AS palabras_unicas
FROM wm_wordcount;

-- 4c. Palabras que aparecen más de 5000 veces
SELECT COUNT(*) AS palabras_muy_frecuentes
FROM wm_wordcount
WHERE total > 5000;

-- 4d. Las 10 palabras menos frecuentes (hápax)
SELECT word, total
FROM wm_wordcount
ORDER BY total ASC
LIMIT 10;
