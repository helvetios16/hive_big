# 1. Crear bucket
aws s3api create-bucket --bucket mi-hive-wordmill --region us-east-1

# 2. Generar texto (~2MB → 200MB server-side, ~1 min)
python3 wordmill/scripts/build_text.py --s3 mi-hive-wordmill

# 3a. Cluster + job sin key pair (solo queries via script)
bash wordmill/scripts/run_hive.sh --bucket mi-hive-wordmill

# 3b. Cluster + job CON key pair (habilita sesión Hive interactiva)
bash wordmill/scripts/run_hive.sh --bucket mi-hive-wordmill --key-pair <nombre-del-key-pair>

# 4. Ver resultados del job inicial (stdout del step de Hive)
aws s3 cp s3://mi-hive-wordmill/logs/<cluster-id>/steps/<step-id>/stdout.gz - | gunzip -c

# 5. Sesión Hive interactiva (requiere haber usado --key-pair en el paso 3b)
bash wordmill/scripts/hive_shell.sh
# Dentro de Hive puedes escribir cualquier consulta:
#   SELECT word, total FROM wm_wordcount ORDER BY total DESC LIMIT 10;
#   SELECT COUNT(*) FROM wm_wordcount;
#   SELECT * FROM wm_wordcount WHERE word = 'light';
#   SELECT word, total FROM wm_wordcount WHERE total BETWEEN 100 AND 500 ORDER BY total DESC LIMIT 20;
#   exit;

# 6. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-3>

# 7. Limpieza total
bash wordmill/scripts/cleanup.sh
