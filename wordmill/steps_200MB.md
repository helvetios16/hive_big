# wordmill — WordCount con Hive en EMR (~200 MB)

## Quickstart completo

```bash
# 0. Crear bucket S3 (solo la primera vez)
aws s3api create-bucket --bucket mi-hive-wordmill --region us-east-1

# 1. Generar texto (~2MB) y replicar a ~200MB en S3 via server-side copy (~1 min)
python3 wordmill/scripts/build_text.py --s3 mi-hive-wordmill

# 2. Crear cluster EMR + ejecutar WordCount (~15-20 min)
bash wordmill/scripts/run_hive.sh --bucket mi-hive-wordmill

# 3. Ver top 20 palabras del resultado
aws s3 cp s3://mi-hive-wordmill/output/000000_0 - | sort -t$'\t' -k2 -rn | head -20

# 4. Terminar cluster (evitar costos)
aws emr terminate-clusters --cluster-ids <cluster-id-del-paso-2>

# 5. Limpieza total (S3 + EMR + local)
bash wordmill/scripts/cleanup.sh
```

## Tiempos estimados

| Paso                             | Tiempo     |
|----------------------------------|------------|
| Paso 1 — generar + subir 200 MB  | ~1 min     |
| Paso 2 — cluster arranca         | ~5-10 min  |
| Paso 2 — job HiveQL              | ~5-8 min   |
| **Total**                        | **~11-19 min** |

## Verificaciones

```bash
# Confirmar que el texto llegó a S3
aws s3 ls s3://mi-hive-wordmill/input/text.txt --human-readable

# Ver estado del cluster
aws emr describe-cluster --cluster-id <id> --query 'Cluster.Status.State'

# Ver logs si el job falla
aws s3 cp s3://mi-hive-wordmill/logs/<cluster-id>/steps/<step-id>/stderr.gz - | gunzip -c
```

## Estructura S3

```
mi-hive-wordmill/
├── input/
│   └── text.txt          ← corpus ~200 MB
├── hql/
│   └── wordcount.hql     ← script HiveQL
├── output/
│   └── 000000_0          ← resultado: word\tcount (TSV)
└── logs/                 ← logs de EMR
```

## Flujo HiveQL (wordcount.hql)

```
texto raw (líneas)
    ↓  SPLIT(LOWER(line), '[^a-z]+')    — tokenización
    ↓  LATERAL VIEW EXPLODE(...)         — una fila por token
    ↓  WHERE LENGTH(word) > 1            — filtro tokens vacíos
    ↓  GROUP BY word                     — agrupación distribuida
    ↓  COUNT(*)                          — conteo por reducer
    ↓
wm_wordcount (word, total)
```
