-- ============================================================
-- Setup de entrada  |  wordmill — Actividad 1
--
-- Este script SOLO prepara la tabla de entrada (texto crudo en S3).
-- El conteo de palabras NO se precalcula aquí: se ejecuta a mano
-- en la sesión interactiva de Hive para poder MEDIR cuánto tarda
-- el job de conteo (Hive imprime "Time taken: N seconds").
-- ============================================================

-- Tabla externa sobre el texto en S3 (1 fila = 1 línea)
DROP TABLE IF EXISTS wm_input;

CREATE EXTERNAL TABLE wm_input (
    line STRING
)
STORED AS TEXTFILE
LOCATION '${hivevar:INPUT}';
