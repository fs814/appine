#!/usr/bin/env python3
"""Restore the large files (over 2 MB) that appine does not carry for Apple's
Metal samples: textures, scenes and models, about 2.1 GB in total.

    fetch_samples.py [SAMPLE_ID ...]     all samples, or only these

Each missing or changed file listed in ../large-files.tsv is extracted from
the sample's zip on developer.apple.com (catalog.json) and checked against
its SHA-256. Zips are cached in ~/Library/Caches/appine/metal-samples/, so a
re-run downloads nothing. Restored files are git-ignored (../.gitignore).
"""
import hashlib, json, os, sys, urllib.request, zipfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.expanduser("~/Library/Caches/appine/metal-samples")

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()

def main(wanted):
    samples = {s["id"]: s for c in json.load(open(os.path.join(HERE, "catalog.json")))["categories"]
               for s in c["samples"]}
    todo = {}
    for line in open(os.path.join(HERE, "large-files.tsv")):
        if line.startswith("#") or not line.strip():
            continue
        sid, rel, size, sha = line.rstrip("\n").split("\t")
        if wanted and sid not in wanted:
            continue
        dest = os.path.join(HERE, samples[sid]["path"], rel)
        if os.path.exists(dest) and os.path.getsize(dest) == int(size) and sha256(dest) == sha:
            continue
        todo.setdefault(sid, []).append((rel, dest, sha))
    if not todo:
        print("All large files are in place.")
        return
    os.makedirs(CACHE, exist_ok=True)
    for sid, files in todo.items():
        zpath = os.path.join(CACHE, sid + ".zip")
        if not os.path.exists(zpath):
            print(f"downloading {sid}.zip ...", flush=True)
            urllib.request.urlretrieve(samples[sid]["zip"].replace("+", "%2B"), zpath + ".part")
            os.rename(zpath + ".part", zpath)
        with zipfile.ZipFile(zpath) as z:
            for rel, dest, sha in files:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with z.open(rel) as src, open(dest, "wb") as out:
                    while block := src.read(1 << 20):
                        out.write(block)
                if sha256(dest) != sha:
                    sys.exit(f"{sid}/{rel}: checksum mismatch; delete {zpath} and re-run")
        print(f"ok {sid}: {len(files)} file(s)")

if __name__ == "__main__":
    main(set(sys.argv[1:]))
