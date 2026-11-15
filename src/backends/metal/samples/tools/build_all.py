#!/usr/bin/env python3
"""Build every sample in ../catalog.json (or the ids given) with build_sample.py.

    build_all.py OUT_DIR [SAMPLE_ID ...]

Writes OUT_DIR/status.json: {id: "ok" | "the reason it did not build"}, which
the Emacs command shows next to each sample.
"""
import concurrent.futures as cf, json, os, subprocess, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(HERE, "tools", "build_sample.py")

def build(sample, out):
    p = subprocess.run([sys.executable, "-I", TOOL, os.path.join(HERE, sample["path"]), out, "--id", sample["id"]],
                       capture_output=True, text=True)
    if p.returncode == 0:
        return sample["id"], "ok"
    msg = (p.stderr or p.stdout).strip().splitlines()
    return sample["id"], "\n".join(msg[:12]).replace(f"FAILED {sample['id']}: ", "")

def main(out, ids):
    os.makedirs(out, exist_ok=True)
    samples = [s for c in json.load(open(os.path.join(HERE, "catalog.json")))["categories"] for s in c["samples"]]
    if ids:
        samples = [s for s in samples if s["id"] in ids]
    status_path = os.path.join(out, "status.json")
    status = json.load(open(status_path)) if os.path.exists(status_path) else {}
    with cf.ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for sid, result in ex.map(lambda s: build(s, out), samples):
            status[sid] = result
            print(("ok     " if result == "ok" else "FAILED ") + sid + ("" if result == "ok" else ": " + result.splitlines()[0][:150]), flush=True)
    json.dump(status, open(status_path, "w"), indent=1, sort_keys=True)
    ok = sum(1 for s in samples if status[s["id"]] == "ok")
    print(f"\n{ok} of {len(samples)} built; details in {status_path} and OUT_DIR/<id>.log")

if __name__ == "__main__":
    main(sys.argv[1], set(sys.argv[2:]))
