-- ============================================================
-- Consultas de referencia  |  wordmill — Actividad 1
--
-- NO se ejecutan automáticamente. Cópialas y pégalas dentro de la
-- sesión interactiva de Hive (wordmill/scripts/hive_shell.sh).
-- Tras cada consulta, Hive imprime "Time taken: N seconds" → ese es
-- el tiempo real que tardó en contar las palabras de forma distribuida.
-- ============================================================

-- Las 10 palabras más frecuentes (lanza el conteo completo y lo mide)
SELECT word, COUNT(*) AS total
FROM wm_input
LATERAL VIEW EXPLODE(SPLIT(LOWER(line), '[^a-z]+')) tokens AS word
WHERE LENGTH(word) > 1
GROUP BY word
ORDER BY total DESC
LIMIT 10;

-- Total de palabras únicas en el corpus
SELECT COUNT(DISTINCT word) AS palabras_unicas
FROM wm_input
LATERAL VIEW EXPLODE(SPLIT(LOWER(line), '[^a-z]+')) tokens AS word
WHERE LENGTH(word) > 1;

-- Salir de Hive
-- exit;
