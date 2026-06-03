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

-- ── C. BUSCAR UNA PALABRA → índice invertido igual que search.py ─────
--    Filtra la palabra ANTES de agrupar, así NO da OOM (no junta los
--    doc_ids de todas las palabras, solo los de esta).
--    Devuelve: doc_id | título | score(tf)  — rankeado por frecuencia,
--    idéntico a lo que muestra el invert (search.py) para una palabra.
--    Cambia 'adventure' por la palabra que busques.
SELECT doc_id, content AS titulo, COUNT(*) AS score
FROM cg_corpus
LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
WHERE word = 'adventure'
GROUP BY doc_id, content
ORDER BY score DESC
LIMIT 10;

-- ── D. BUSCAR VARIAS PALABRAS (AND) → igual que search.py ────────────
--    Devuelve los docs que contienen TODAS las palabras, rankeados por
--    score (suma de frecuencias). El HAVING = nº de palabras hace el AND.
--    OJO: con este corpus cada doc es un título corto, así que elige
--    palabras que aparezcan juntas en un mismo título (ej: Twenty Years After).
SELECT doc_id, content AS titulo, COUNT(*) AS score
FROM cg_corpus
LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
WHERE word IN ('twenty', 'years', 'after')
GROUP BY doc_id, content
HAVING COUNT(DISTINCT word) = 3      -- nº de palabras buscadas (AND)
ORDER BY score DESC
LIMIT 10;

-- Salir de Hive
-- exit;
