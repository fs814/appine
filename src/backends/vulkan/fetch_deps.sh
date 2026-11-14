#!/usr/bin/env bash
# Download what Vulkan-Samples needs but appine does not carry: its third-party
# libraries (about 525 MB) and its assets (about 1 GB). They go into the
# git-ignored folders Vulkan-Samples/third_party/<name> and Vulkan-Samples/assets,
# each at the exact commit upstream pins (deps.tsv). Safe to re-run: a folder
# already at its pinned commit is skipped.
#
# Usage: ./fetch_deps.sh            everything
#        ./fetch_deps.sh --no-assets   libraries only (samples that load scenes
#                                      or textures will then fail to start)
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$HERE/Vulkan-Samples"
WITH_ASSETS=1
[[ "${1:-}" == "--no-assets" ]] && WITH_ASSETS=0

command -v git >/dev/null || { echo "git not found." >&2; exit 1; }

while IFS=$'\t' read -r dep url commit; do
    [[ -z "$dep" || "$dep" == \#* ]] && continue
    if [[ "$dep" == assets && $WITH_ASSETS -eq 0 ]]; then
        continue
    fi
    dir="$ROOT/$dep"
    if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" == "$commit" && -d "$dir/.git" ]]; then
        echo "ok       $dep"
        continue
    fi
    echo "fetching $dep ($url @ ${commit:0:10})"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
done < "$HERE/deps.tsv"

echo ""
echo "Dependencies ready under $ROOT"
echo "Next: make vulkan-samples   (in the appine checkout)"
