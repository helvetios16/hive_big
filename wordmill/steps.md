# 1. Crear bucket
aws s3api create-bucket --bucket mi-hive-wordmill --region us-east-1

# 2. Generar texto (~2MB → 200MB server-side, ~1 min)
python3 wordmill/scripts/build_text.py --s3 mi-hive-wordmill

# 3. Cluster + job (~10-17 min)
bash wordmill/scripts/run_hive.sh --bucket mi-hive-wordmill

# 4. Ver resultados de las consultas (stdout del step de Hive)
aws s3 cp s3://mi-hive-wordmill/logs/<cluster-id>/steps/<step-id>/stdout.gz - | gunzip -c

# 5. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-3>

# 6. Limpieza total
bash wordmill/scripts/cleanup.sh
