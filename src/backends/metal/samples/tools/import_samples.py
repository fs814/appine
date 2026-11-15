#!/usr/bin/env python3
"""Copy Apple's Metal sample code library into appine, by the web page's categories.

    import_samples.py LIBRARY_JSON SAMPLES_JSON EXTRACTED_DIR

LIBRARY_JSON is developer.apple.com's JSON for
/documentation/metal/metal-sample-code-library (its topic sections are the
categories, in the page's order); SAMPLES_JSON maps each sample to its zip
(made while downloading); EXTRACTED_DIR holds one unzipped folder per zip.

Writes, next to this tools/ folder:
  <category-slug>/<SampleName>/   the sample, without files over 2 MB
  catalog.json                    categories and samples, in the page's order
  large-files.tsv                 the files left out, restored by fetch_samples.py

Then applies tools/patches/<SampleName>.patch, the few local fixes a sample
needs to run inside Emacs (each patch says why at its top).
"""
import hashlib, json, os, re, shutil, subprocess, sys

LIMIT = 2 * 1024 * 1024
SKIP_DIRS = {".git", "__MACOSX", "xcuserdata", ".swiftpm"}
SKIP_FILES = {".DS_Store"}

def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")

def main(library_json, samples_json, extracted):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lib = json.load(open(library_json))
    zips = {s["url"]: s["zip"] for s in json.load(open(samples_json))}
    refs = lib["references"]
    catalog = {"source": "https://developer.apple.com/documentation/metal/metal-sample-code-library",
               "categories": []}
    large = []
    for section in lib["topicSections"]:
        cat = {"title": section["title"], "slug": slug(section["title"]), "samples": []}
        for ident in section["identifiers"]:
            ref = refs[ident]
            zip_rel = zips[ref["url"]]
            name = os.path.basename(zip_rel)[:-4]
            src = os.path.join(extracted, name)
            dst = os.path.join(here, cat["slug"], name)
            if os.path.exists(dst):
                shutil.rmtree(dst)
            for root, dirs, files in os.walk(src):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for f in files:
                    if f in SKIP_FILES:
                        continue
                    path = os.path.join(root, f)
                    rel = os.path.relpath(path, src)
                    size = os.path.getsize(path)
                    if size > LIMIT:
                        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
                        large.append((name, rel, size, sha))
                        continue
                    out = os.path.join(dst, rel)
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    shutil.copy2(path, out)
            # Local fixes, each explained at the top of its patch file.
            patch = os.path.join(here, "tools", "patches", name + ".patch")
            if os.path.exists(patch):
                subprocess.run(["patch", "-p1", "-s", "-d", dst, "-i", patch], check=True)
            abstract = "".join(a.get("text", "") for a in ref.get("abstract", []))
            cat["samples"].append({"id": name, "title": ref["title"], "abstract": abstract,
                                   "path": f"{cat['slug']}/{name}",
                                   "doc": "https://developer.apple.com" + ref["url"],
                                   "zip": "https://docs-assets.developer.apple.com/published/" + zip_rel})
        catalog["categories"].append(cat)
    with open(os.path.join(here, "catalog.json"), "w") as fh:
        json.dump(catalog, fh, indent=1, ensure_ascii=False)
    with open(os.path.join(here, "large-files.tsv"), "w") as fh:
        fh.write("# sample\tpath in the sample\tbytes\tsha256   (restored by tools/fetch_samples.py)\n")
        for row in sorted(large):
            fh.write("\t".join(map(str, row)) + "\n")
    n = sum(len(c["samples"]) for c in catalog["categories"])
    print(f"{n} samples in {len(catalog['categories'])} categories; {len(large)} large files left out")

if __name__ == "__main__":
    main(*sys.argv[1:4])
