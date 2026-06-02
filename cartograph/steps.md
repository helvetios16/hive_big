# ============================================================
# cartograph — Índice Invertido en Hive (Actividad 2)
# Reutiliza el corpus que ya subió invert_index_emr a S3.
# Bucket: mi-indice-gutenberg   (input/corpus.txt = doc_id TAB título)
# ============================================================

# 1. Verificar que el corpus ya está en S3 (NO hay que generarlo de nuevo)
aws s3 ls s3://mi-indice-gutenberg/input/corpus.txt --human-readable
#    Si no existe, genéralo:
#      python3 cartograph/scripts/build_corpus.py --target-mb 200 --s3 mi-indice-gutenberg

# 2. (una vez) Key pair para la sesión Hive interactiva — si aún no tienes
aws ec2 create-key-pair --key-name cartograph-kp \
  --query KeyMaterial --output text > ~/cartograph-kp.pem
chmod 600 ~/cartograph-kp.pem

# 3. Cluster + tabla de corpus (NO precalcula el índice; solo crea cg_corpus)
#    --core-count escala los nodos CORE; el script sondea cada 30s con timer
#    y al final muestra los tiempos por etapa.
bash cartograph/scripts/run_hive.sh \
  --bucket mi-indice-gutenberg \
  --key-pair cartograph-kp \
  --core-count 3

# 4. Sesión Hive interactiva — AQUÍ se construye el índice y se mide el tiempo
bash cartograph/scripts/hive_shell.sh

# 5. Dentro de Hive, escribe la consulta TÚ MISMO. Hive imprime "Time taken: N seconds"
#    al terminar → ese es el tiempo real del índice invertido distribuido.
#    (consultas de referencia en cartograph/hql/queries.hql)
#
#   SET hive.exec.reducers.bytes.per.reducer=67108864;
#
#   (A y B filtran las mismas ~50 stopwords que mapper.py → comparación justa
#    con invert_index_emr; lista completa en cartograph/hql/queries.hql)
#
#   -- A. Frecuencia de documento (ligera, ideal para cronometrar):
#   SELECT word, COUNT(DISTINCT doc_id) AS doc_count
#   FROM cg_corpus
#   LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
#   WHERE LENGTH(word) > 1 AND word NOT IN ('the','a','an','and','of','to', ... )
#   GROUP BY word
#   ORDER BY doc_count DESC
#   LIMIT 20;
#
#   -- B. Índice invertido completo (postings list, más pesada):
#   SELECT word, COUNT(DISTINCT doc_id) AS doc_count,
#          concat_ws(',', collect_set(doc_id)) AS doc_list
#   FROM cg_corpus
#   LATERAL VIEW EXPLODE(SPLIT(LOWER(content), '[^a-z]+')) t AS word
#   WHERE LENGTH(word) > 1 AND word NOT IN ('the','a','an','and','of','to', ... )
#   GROUP BY word ORDER BY doc_count DESC LIMIT 20;
#
#   exit;

# 6. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-3>

# 7. Limpieza — PRESERVA el bucket y el corpus (solo borra cluster + output/hql/logs + locales)
bash cartograph/scripts/cleanup.sh
