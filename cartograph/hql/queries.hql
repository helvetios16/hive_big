-- ============================================================
-- Consultas de referencia  |  cartograph — Actividad 2
--
-- NO se ejecutan automáticamente. Cópialas y pégalas dentro de la
-- sesión interactiva de Hive (cartograph/scripts/hive_shell.sh).
-- Tras cada consulta, Hive imprime "Time taken: N seconds" → ese es
-- el tiempo real que tardó en construir el índice de forma distribuida.
--
-- NOTA: las consultas A y B filtran las MISMAS ~50 stopwords que el
-- mapper.py de invert_index_emr, para que la comparación Hive vs
-- MapReduce sea justa (mismo trabajo, mismas palabras descartadas).
--
-- Más reducers para repartir la carga del índice (palabras muy frecuentes):
SET hive.exec.reducers.bytes.per.reducer=67108864;

-- ── A. Frecuencia de documento (LIGERA — ideal para medir tiempo) ────
--    Para cada palabra, en cuántos documentos distintos aparece.
--    Es el núcleo del índice invertido y no construye listas en memoria,
--    así que es la consulta más segura para cronometrar.
SELECT word, COUNT(DISTINCT doc_id) AS doc_count
FROM cg_corpus
LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
WHERE LENGTH(word) > 1
  -- mismas stopwords que mapper.py de invert_index_emr (comparación justa)
  AND word NOT IN (
    'the','a','an','and','or','but','in','on','at','to','for',
    'of','with','is','it','this','that','was','are','be','as',
    'by','from','not','have','had','has','he','she','they','we',
    'you','i','do','did','so','if','up','out','no','its','my',
    'me','him','her','his','our','your','their','been','were'
  )
GROUP BY word
ORDER BY doc_count DESC
LIMIT 20;

-- ── B. Índice invertido completo (PESADA — postings list real) ───────
--    word → nº de docs + lista de doc_ids que la contienen.
--    OJO: collect_set junta TODOS los doc_ids de cada palabra en un
--    reducer; con corpus grande y palabras muy frecuentes puede usar
--    mucha memoria. Si falla por OOM, usa la consulta A o más cores.
SELECT
    word,
    COUNT(DISTINCT doc_id)               AS doc_count,
    concat_ws(',', collect_set(doc_id))  AS doc_list
FROM cg_corpus
LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
WHERE LENGTH(word) > 1
  -- mismas stopwords que mapper.py de invert_index_emr (comparación justa)
  AND word NOT IN (
    'the','a','an','and','or','but','in','on','at','to','for',
    'of','with','is','it','this','that','was','are','be','as',
    'by','from','not','have','had','has','he','she','they','we',
    'you','i','do','did','so','if','up','out','no','its','my',
    'me','him','her','his','our','your','their','been','were'
  )
GROUP BY word
ORDER BY doc_count DESC
LIMIT 20;

-- ── C. Buscar una palabra concreta en el índice ──────────────────────
SELECT
    word,
    COUNT(DISTINCT doc_id)                          AS doc_count,
    SUBSTR(concat_ws(',', collect_set(doc_id)), 1, 120) AS doc_sample
FROM cg_corpus
LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
WHERE word = 'adventure'
GROUP BY word;

-- Salir de Hive
-- exit;
