# 1. Crear bucket
aws s3api create-bucket --bucket mi-hive-wordmill --region us-east-1

# 2. Generar texto (~2MB → 200MB server-side, ~1 min)
python3 wordmill/scripts/build_text.py --s3 mi-hive-wordmill

# 3. Cluster + tabla de entrada (usa --key-pair para habilitar la sesión interactiva)
#    El conteo NO se precalcula: el step solo deja lista la tabla wm_input.
#    El script sondea cada 30s y muestra un timer [mm:ss] por etapa; al final
#    imprime un resumen con la duración de cada fase:
#      ── Tiempos ──
#        Aprovisionar cluster : <mm:ss>   (crear EMR + estado WAITING, ~5-8 min)
#        Setup tabla (step)   : <mm:ss>   (crear wm_input, ~1 min)
bash wordmill/scripts/run_hive.sh --bucket mi-hive-wordmill --key-pair <nombre-del-key-pair>

# 4. (opcional) Ver el log del step de setup
aws s3 cp s3://mi-hive-wordmill/logs/<cluster-id>/steps/<step-id>/stdout.gz - | gunzip -c

# 5. Sesión Hive interactiva — AQUÍ se cuenta de verdad
bash wordmill/scripts/hive_shell.sh

# 6. Dentro de Hive, escribe el conteo TÚ MISMO. Hive imprime "Time taken: N seconds"
#    al terminar → ese es el TIEMPO REAL DEL CONTEO distribuido (etapa clave a medir,
#    independiente de los tiempos de preparación del paso 3).
#    (consultas de referencia en wordmill/hql/queries.hql)
#
#   -- Las 10 palabras más frecuentes:
#   SELECT word, COUNT(*) AS total
#   FROM wm_input
#   LATERAL VIEW EXPLODE(SPLIT(LOWER(line), '[^a-z]+')) tokens AS word
#   WHERE LENGTH(word) > 1
#   GROUP BY word
#   ORDER BY total DESC
#   LIMIT 10;
#
#   exit;

# 7. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-3>

# 8. Limpieza total
bash wordmill/scripts/cleanup.sh
