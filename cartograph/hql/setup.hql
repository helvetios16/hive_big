-- ============================================================
-- Setup de entrada  |  cartograph — Actividad 2 (Índice Invertido)
--
-- Este script SOLO prepara la tabla de entrada (corpus en S3).
-- El índice invertido NO se precalcula aquí: se ejecuta a mano en
-- la sesión interactiva de Hive para poder MEDIR cuánto tarda
-- (Hive imprime "Time taken: N seconds").
--
-- Corpus reutilizado de invert_index_emr:
--   s3://<bucket>/input/corpus.txt   →   doc_id <TAB> contenido(título)
-- ============================================================

-- Tabla externa sobre el corpus en S3 (doc_id TAB content)
DROP TABLE IF EXISTS cg_corpus;

CREATE EXTERNAL TABLE cg_corpus (
    doc_id  STRING,
    content STRING
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION '${hivevar:INPUT}';
