#!/usr/bin/env bash
# Generate the one-file patches used by the warm-build scenarios, against the
# exact sources pinned in docker-bake.hcl.
#
#   bench/make-patches.sh            -> bench/patches/<scenario>/<package>/9999-<scenario>.patch
#
#   W1a  vLLM Python only   vllm/logger.py            (no native input changes)
#   W1b  vLLM one HIP TU    csrc/cache_kernels.cu     (one real compile miss)
#   W2   LMCache one TU     csrc/mem_kernels.cu
#   W3   torch one TU       aten/src/ATen/native/Activation.cpp
# Each patch appends real code (a new unused function), not a comment: sccache
# hashes preprocessed source, so a comment-only change would still be a hit.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
out="$repo/bench/patches"
vars=$(docker buildx bake -f "$repo/docker-bake.hcl" --list type=variables,format=json)
var() { python3 -c 'import json,sys; print({v["name"]: v.get("value","") for v in json.load(sys.stdin)}[sys.argv[1]])' "$1" <<< "$vars"; }

make_patch() { # make_patch <scenario> <package> <owner/repo> <sha> <path> <appended text>
    local scenario=$1 pkg=$2 gh_repo=$3 sha=$4 path=$5 text=$6 tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/a/$(dirname "$path")" "$tmp/b/$(dirname "$path")" "$out/$scenario/$pkg"
    curl -fsSL "https://raw.githubusercontent.com/$gh_repo/$sha/$path" -o "$tmp/a/$path"
    cp "$tmp/a/$path" "$tmp/b/$path"
    printf '\n%s\n' "$text" >> "$tmp/b/$path"
    (cd "$tmp" && diff -u "a/$path" "b/$path" > "$out/$scenario/$pkg/9999-$scenario.patch") || [ $? -eq 1 ]
    rm -rf "$tmp"
    echo "$out/$scenario/$pkg/9999-$scenario.patch"
}

make_patch W1a vllm vllm-project/vllm "$(var VLLM_SHA)" vllm/logger.py \
    'def _rpb_w1a_marker() -> int:
    return 1'
make_patch W1b vllm vllm-project/vllm "$(var VLLM_SHA)" csrc/cache_kernels.cu \
    'int rpb_w1b_marker() { return 1; }'
make_patch W2 lmcache LMCache/LMCache "$(var LMCACHE_SHA)" csrc/mem_kernels.cu \
    'int rpb_w2_marker() { return 1; }'
make_patch W3 pytorch pytorch/pytorch "$(var TORCH_SHA)" aten/src/ATen/native/Activation.cpp \
    'int rpb_w3_marker() { return 1; }'
