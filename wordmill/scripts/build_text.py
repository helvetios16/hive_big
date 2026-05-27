#!/usr/bin/env python3
"""
Genera texto en inglés (~2MB) y lo replica en S3 hasta ~200MB con server-side copy.

Uso:
  python3 wordmill/scripts/build_text.py                              # solo local
  python3 wordmill/scripts/build_text.py --s3 mi-hive-wordmill        # 200MB en S3
  python3 wordmill/scripts/build_text.py --target-mb 500 --s3 <bucket>
"""
import os
import sys
import io
import math
import random

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ~300 palabras en inglés con distribución realista de frecuencias
NOUNS = [
    "time", "year", "people", "way", "day", "man", "woman", "child", "world",
    "life", "hand", "part", "place", "week", "number", "night", "point",
    "home", "water", "room", "mother", "money", "story", "fact", "month",
    "eye", "job", "word", "business", "side", "head", "house", "friend",
    "father", "power", "hour", "game", "line", "end", "city", "river",
    "mountain", "forest", "ocean", "island", "country", "village", "bridge",
    "garden", "market", "school", "library", "hospital", "station", "tower",
    "music", "science", "history", "culture", "language", "nature", "energy",
    "light", "sound", "force", "space", "earth", "fire", "wind", "storm",
    "rain", "cloud", "sun", "moon", "star", "sky", "technology", "network",
    "data", "knowledge", "result", "method", "value", "level", "form",
    "action", "group", "human", "society", "economy", "health", "education",
    "research", "production", "growth", "market", "cost", "rate", "theory",
    "practice", "experience", "quality", "situation", "condition", "process",
    "structure", "pattern", "strategy", "decision", "solution", "question",
    "answer", "problem", "reason", "purpose", "meaning", "truth", "peace",
    "war", "love", "dream", "hope", "fear", "danger", "freedom", "justice",
]

VERBS = [
    "come", "think", "know", "take", "see", "want", "give", "use", "find",
    "tell", "ask", "feel", "try", "leave", "call", "keep", "begin", "show",
    "hear", "play", "run", "move", "live", "believe", "hold", "bring",
    "write", "provide", "stand", "learn", "change", "lead", "watch", "follow",
    "stop", "create", "speak", "read", "grow", "walk", "build", "fall",
    "reach", "remain", "suggest", "raise", "pass", "require", "decide",
    "work", "travel", "explore", "discover", "understand", "consider",
    "represent", "contain", "describe", "produce", "develop", "increase",
    "reduce", "improve", "measure", "connect", "reflect", "support",
]

ADJECTIVES = [
    "strong", "clear", "deep", "wide", "fast", "slow", "bright", "dark",
    "long", "short", "hard", "soft", "warm", "cold", "sharp", "smooth",
    "complex", "simple", "ancient", "modern", "common", "rare", "vast",
    "central", "local", "global", "natural", "open", "free", "new", "old",
    "great", "small", "large", "high", "low", "good", "bad", "true", "false",
    "important", "different", "possible", "public", "private", "real",
    "beautiful", "powerful", "quiet", "loud", "rich", "poor", "young", "early",
]

CONNECTORS = [
    "however", "therefore", "moreover", "meanwhile", "although", "because",
    "while", "since", "unless", "whether", "beyond", "across", "between",
    "during", "through", "around", "among", "within", "without", "toward",
]


def make_sentence(rng):
    pattern = rng.randint(0, 5)
    if pattern == 0:
        # noun verb adjective noun
        return (f"The {rng.choice(ADJECTIVES)} {rng.choice(NOUNS)} "
                f"can {rng.choice(VERBS)} every {rng.choice(NOUNS)}.")
    elif pattern == 1:
        return (f"{rng.choice(CONNECTORS).capitalize()}, "
                f"{rng.choice(NOUNS)} and {rng.choice(NOUNS)} "
                f"{rng.choice(VERBS)} together.")
    elif pattern == 2:
        return (f"Every {rng.choice(ADJECTIVES)} {rng.choice(NOUNS)} "
                f"must {rng.choice(VERBS)} the {rng.choice(NOUNS)}.")
    elif pattern == 3:
        return (f"The {rng.choice(NOUNS)} of {rng.choice(NOUNS)} "
                f"shapes our {rng.choice(ADJECTIVES)} {rng.choice(NOUNS)}.")
    elif pattern == 4:
        words = rng.choices(NOUNS + VERBS + ADJECTIVES, k=rng.randint(5, 10))
        words[0] = words[0].capitalize()
        return " ".join(words) + "."
    else:
        return (f"{rng.choice(ADJECTIVES).capitalize()} {rng.choice(NOUNS)} "
                f"{rng.choice(VERBS)} {rng.choice(CONNECTORS)} "
                f"{rng.choice(ADJECTIVES)} {rng.choice(NOUNS)}.")


def generate_text(target_bytes, seed=42):
    rng = random.Random(seed)
    lines = []
    total = 0
    while total < target_bytes:
        n_sentences = rng.randint(3, 7)
        para = " ".join(make_sentence(rng) for _ in range(n_sentences))
        line = para + "\n"
        encoded = line.encode("utf-8")
        lines.append(encoded)
        total += len(encoded)
    return b"".join(lines)


# ── Local ──────────────────────────────────────────────────────────────────────

def write_local(text_file, target_mb=2):
    target_bytes = target_mb * 1024 * 1024
    os.makedirs(os.path.dirname(text_file), exist_ok=True)
    print(f"Generando texto (~{target_mb}MB)...", end=" ", flush=True)
    data = generate_text(target_bytes)
    with open(text_file, "wb") as f:
        f.write(data)
    size_mb = len(data) / 1024 / 1024
    lines = data.count(b"\n")
    print(f"✓  {lines:,} líneas / {size_mb:.1f} MB")
    return data


# ── S3 server-side copy ────────────────────────────────────────────────────────

def stream_to_s3_copy(base_data, target_mb, bucket):
    import boto3
    s3 = boto3.client("s3")

    target_bytes = target_mb * 1024 * 1024
    actual_base  = len(base_data)
    num_copies   = max(1, round(target_bytes / actual_base))

    if num_copies > 9_999:
        print("WARN: demasiadas partes. Reduce --target-mb o aumenta el chunk base.")
        num_copies = 9_999

    corpus_key = "input/text.txt"
    base_key   = "input/text_base.txt"

    print(f"  Estrategia  : S3 server-side copy")
    print(f"  Chunk base  : {actual_base / 1024 / 1024:.1f} MB")
    print(f"  Copias S3   : {num_copies} x {actual_base / 1024 / 1024:.1f} MB"
          f"  →  ≈{actual_base * num_copies / 1024**2:.0f} MB")
    print()

    print("  [1/4] Limpiando input anterior...", end=" ", flush=True)
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix="input/"):
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": objs})
    print("✓")

    print(f"  [2/4] Subiendo chunk base ({actual_base / 1024 / 1024:.1f} MB)...",
          end=" ", flush=True)
    s3.put_object(Bucket=bucket, Key=base_key, Body=base_data, ContentType="text/plain")
    print("✓")

    print(f"  [3/4] Limpiando output anterior...", end=" ", flush=True)
    for page in paginator.paginate(Bucket=bucket, Prefix="output/"):
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": objs})
    print("✓")

    print(f"  [4/4] Ensamblando corpus ({num_copies} copias, 0 bytes por red)...")
    mpu = s3.create_multipart_upload(Bucket=bucket, Key=corpus_key,
                                     ContentType="text/plain")
    upload_id = mpu["UploadId"]

    try:
        parts = []
        for i in range(num_copies):
            part_num = i + 1
            resp = s3.upload_part_copy(
                Bucket=bucket, Key=corpus_key,
                PartNumber=part_num, UploadId=upload_id,
                CopySource={"Bucket": bucket, "Key": base_key},
            )
            parts.append({"PartNumber": part_num,
                           "ETag": resp["CopyPartResult"]["ETag"]})
            if part_num % 10 == 0 or part_num == num_copies:
                done_mb = actual_base * part_num / 1024**2
                print(f"        {part_num}/{num_copies} partes  ({done_mb:.0f} MB)...",
                      end="\r")

        s3.complete_multipart_upload(
            Bucket=bucket, Key=corpus_key, UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )
        total_mb = actual_base * num_copies / 1024**2
        print(f"\n  ✓ text.txt  →  s3://{bucket}/{corpus_key}  ({total_mb:.0f} MB)")

    except Exception:
        s3.abort_multipart_upload(Bucket=bucket, Key=corpus_key, UploadId=upload_id)
        raise
    finally:
        s3.delete_object(Bucket=bucket, Key=base_key)


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    base_mb    = 2
    target_mb  = 200
    s3_bucket  = None

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--target-mb":
            target_mb = int(args[i + 1]); i += 2
        elif args[i] == "--s3":
            s3_bucket = args[i + 1]; i += 2
        else:
            i += 1

    text_file = os.path.join(ROOT, "wordmill", "data", "text.txt")
    base_data = write_local(text_file, target_mb=base_mb)

    if s3_bucket:
        print(f"\nModo: S3 server-side copy  →  ~{target_mb} MB")
        print()
        stream_to_s3_copy(base_data, target_mb, s3_bucket)
        print()
        print("Siguiente paso:")
        print(f"  bash wordmill/scripts/run_hive.sh --bucket {s3_bucket}")
    else:
        print()
        print("Siguiente paso:")
        print(f"  bash wordmill/scripts/run_hive.sh --bucket <bucket>")
        print(f"  (o sube primero: python3 wordmill/scripts/build_text.py --s3 <bucket>)")


if __name__ == "__main__":
    main()
