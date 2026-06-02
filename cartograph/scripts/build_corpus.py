#!/usr/bin/env python3
"""
Genera el corpus Gutenberg para el índice invertido y lo sube a S3.
Formato por línea:  doc_NNNNN.txt TAB título del libro

Adaptado de invert_index_emr/scripts/build_corpus.py.

Uso:
  # Solo local (~1.8 MB con los 39K títulos)
  python3 cartograph/scripts/build_corpus.py

  # Directo a S3 con server-side copy hasta ~200 MB (~1 min)
  # (normalmente NO hace falta: cartograph reutiliza el corpus de invert_index_emr)
  python3 cartograph/scripts/build_corpus.py --target-mb 200 --s3 mi-indice-gutenberg
"""
import os
import sys
import io
import math

ROOT       = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CART_DIR   = os.path.join(ROOT, 'cartograph')
TITLES_FILE = os.path.join(CART_DIR, 'titles.txt')


# ── Corpus local ──────────────────────────────────────────────────────────────

def write_local(titles, corpus_file, map_file):
    total  = len(titles)
    digits = len(str(total))
    os.makedirs(os.path.dirname(corpus_file), exist_ok=True)

    with open(corpus_file, 'w', encoding='utf-8') as cf, \
         open(map_file,    'w', encoding='utf-8') as mf:
        for doc_num, title in enumerate(titles, 1):
            doc_id = f"doc_{doc_num:0{digits}d}.txt"
            line   = f"{doc_id}\t{title}\n"
            cf.write(line)
            mf.write(line)

    size_mb = os.path.getsize(corpus_file) / 1024 / 1024
    print(f"✓ corpus.txt  : {total:,} docs  /  {size_mb:.1f} MB")
    print(f"✓ doc_map.txt : {total:,} entradas")


# ── S3 server-side copy ───────────────────────────────────────────────────────

def stream_to_s3_copy(titles, target_mb, bucket):
    """
    1. Genera un chunk base de ~50 MB en memoria y lo sube a S3 (único upload real)
    2. Replica server-side hasta alcanzar target_mb  (0 bytes por red adicionales)
    Tiempo típico: ~30-60 s para 200 MB.
    """
    import boto3
    s3 = boto3.client('s3')

    target_bytes = target_mb * 1024 * 1024
    single_bytes = sum(len(f"doc_00000.txt\t{t}\n".encode('utf-8')) for t in titles)

    PART_BYTES   = 50 * 1024 * 1024          # chunk base ~50 MB (> mínimo S3 de 5 MB)
    base_repeats = max(1, math.ceil(PART_BYTES / single_bytes))
    base_est     = single_bytes * base_repeats

    num_copies = max(1, round(target_bytes / base_est))
    if num_copies > 9_999:                   # límite S3: 10 000 partes
        base_repeats = math.ceil(target_bytes / (9_999 * single_bytes))
        base_est     = single_bytes * base_repeats
        num_copies   = math.ceil(target_bytes / base_est)

    print(f"  Estrategia  : S3 server-side copy")
    print(f"  Chunk base  : {base_repeats:,}x títulos  ≈ {base_est/1024/1024:.0f} MB")
    print(f"  Copias S3   : {num_copies} × ≈{base_est/1024/1024:.0f} MB"
          f"  →  ≈{base_est * num_copies / 1024**2:.0f} MB")
    print()

    # ── 1. Generar chunk base en memoria ──────────────────────────────────────
    print("  [1/5] Generando chunk base en memoria...", end=' ', flush=True)
    digits  = len(str(len(titles) * base_repeats))
    buf     = io.BytesIO()
    doc_num = 1
    for _ in range(base_repeats):
        for title in titles:
            buf.write(f"doc_{doc_num:0{digits}d}.txt\t{title}\n".encode('utf-8'))
            doc_num += 1
    base_data   = buf.getvalue()
    actual_base = len(base_data)
    print(f"✓  ({actual_base/1024/1024:.1f} MB)")

    corpus_key = 'input/corpus.txt'
    base_key   = 'input/corpus_base.txt'
    paginator  = s3.get_paginator('list_objects_v2')

    # ── 2. Limpiar input anterior ──────────────────────────────────────────────
    print("  [2/5] Limpiando input/ anterior en S3...", end=' ', flush=True)
    for page in paginator.paginate(Bucket=bucket, Prefix='input/'):
        objs = [{'Key': o['Key']} for o in page.get('Contents', [])]
        if objs:
            s3.delete_objects(Bucket=bucket, Delete={'Objects': objs})
    print("✓")

    # ── 3. Subir chunk base ────────────────────────────────────────────────────
    print(f"  [3/5] Subiendo chunk base ({actual_base/1024/1024:.1f} MB)...",
          end=' ', flush=True)
    s3.put_object(Bucket=bucket, Key=base_key, Body=base_data, ContentType='text/plain')
    print("✓")

    # ── 4. Multipart copy server-side ─────────────────────────────────────────
    print(f"  [4/5] Ensamblando corpus ({num_copies} copias, 0 bytes por red)...")
    mpu       = s3.create_multipart_upload(Bucket=bucket, Key=corpus_key,
                                           ContentType='text/plain')
    upload_id = mpu['UploadId']

    try:
        parts = []
        for i in range(num_copies):
            part_num = i + 1
            resp = s3.upload_part_copy(
                Bucket=bucket, Key=corpus_key,
                PartNumber=part_num, UploadId=upload_id,
                CopySource={'Bucket': bucket, 'Key': base_key},
            )
            parts.append({'PartNumber': part_num,
                          'ETag': resp['CopyPartResult']['ETag']})
            if part_num % 5 == 0 or part_num == num_copies:
                done_mb = actual_base * part_num / 1024**2
                print(f"        {part_num}/{num_copies} partes  ({done_mb:.0f} MB)...",
                      end='\r')

        s3.complete_multipart_upload(
            Bucket=bucket, Key=corpus_key, UploadId=upload_id,
            MultipartUpload={'Parts': parts},
        )
        total_mb = actual_base * num_copies / 1024**2
        print(f"\n  ✓ corpus.txt  →  s3://{bucket}/{corpus_key}  ({total_mb:.0f} MB)")

    except Exception:
        s3.abort_multipart_upload(Bucket=bucket, Key=corpus_key, UploadId=upload_id)
        raise
    finally:
        s3.delete_object(Bucket=bucket, Key=base_key)

    return digits, base_repeats


def upload_doc_map(titles, bucket, digits, base_repeats):
    """Sube doc_map.txt a S3 (doc_id → título) con los IDs del chunk base."""
    import boto3
    s3    = boto3.client('s3')
    lines = []
    doc_num = 1
    for _ in range(base_repeats):
        for title in titles:
            lines.append(f"doc_{doc_num:0{digits}d}.txt\t{title}\n")
            doc_num += 1

    content = ''.join(lines).encode('utf-8')
    s3.put_object(Bucket=bucket, Key='doc_map.txt', Body=content)
    size_mb = len(content) / 1024 / 1024
    total   = len(titles) * base_repeats
    print(f"  ✓ doc_map.txt →  s3://{bucket}/doc_map.txt  ({total:,} entradas / {size_mb:.1f} MB)")


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    target_mb = None
    s3_bucket = None

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--target-mb':
            target_mb = int(args[i + 1]); i += 2
        elif args[i] == '--s3':
            s3_bucket = args[i + 1]; i += 2
        else:
            i += 1

    with open(TITLES_FILE, 'r', encoding='utf-8') as f:
        titles = [line.strip() for line in f if line.strip()]

    print(f"Títulos Gutenberg : {len(titles):,}")

    if s3_bucket:
        mb = target_mb or 200
        print(f"Target            : ~{mb} MB en S3")
        print(f"Modo              : S3 server-side copy")
        print()
        digits, base_repeats = stream_to_s3_copy(titles, mb, s3_bucket)

        print()
        print("  [5/5] Subiendo doc_map.txt...", end=' ', flush=True)
        upload_doc_map(titles, s3_bucket, digits, base_repeats)

        print()
        print("Siguiente paso:")
        print(f"  bash cartograph/scripts/run_hive.sh --bucket {s3_bucket}")

    else:
        corpus_file = os.path.join(CART_DIR, 'data', 'corpus.txt')
        map_file    = os.path.join(CART_DIR, 'data', 'doc_map.txt')
        print(f"Modo              : local")
        print()
        write_local(titles, corpus_file, map_file)
        print()
        print("Siguiente paso:")
        print(f"  bash cartograph/scripts/run_hive.sh --bucket <bucket>")


if __name__ == '__main__':
    main()
