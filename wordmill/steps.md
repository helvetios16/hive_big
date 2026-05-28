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

# 5a. Sesión Hive interactiva (requiere haber usado --key-pair en el paso 3b)
bash wordmill/scripts/hive_shell.sh --key ~/.ssh/mi-key.pem
# Dentro de Hive puedes escribir cualquier consulta:
#   SELECT word, total FROM wm_wordcount ORDER BY total DESC LIMIT 10;
#   SELECT COUNT(*) FROM wm_wordcount;
#   exit;

# 5b. Query rápida sin entrar al shell (no necesita key pair)
bash wordmill/scripts/query.sh "SELECT word, total FROM wm_wordcount ORDER BY total DESC LIMIT 10"
bash wordmill/scripts/query.sh "SELECT COUNT(*) FROM wm_wordcount"
bash wordmill/scripts/query.sh "SELECT * FROM wm_wordcount WHERE word = 'light'"
bash wordmill/scripts/query.sh "SELECT word, total FROM wm_wordcount WHERE total BETWEEN 100 AND 500 ORDER BY total DESC LIMIT 20"

# 6. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-3>

# 7. Limpieza total
bash wordmill/scripts/cleanup.sh
