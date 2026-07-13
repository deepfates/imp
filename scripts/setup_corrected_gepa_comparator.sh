#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 TARGET_DIR" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
evidence_dir="$repo_root/benchmarks/upstream/gepa-corrected"
target=$1

if [ -e "$target" ]; then
  echo "target already exists: $target" >&2
  exit 73
fi

GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/gepa-ai/gepa-artifact.git "$target"
git -C "$target" checkout --detach cbefbc1aa0f43dd39874ec4bf42211365dbda42e

GIT_LFS_SKIP_SMUDGE=1 git clone \
  https://github.com/gepa-ai/dspy.git \
  "$target/gepa_artifact/utils/dspy"
git -C "$target/gepa_artifact/utils/dspy" checkout --detach \
  62dc3b634d7dc0c4889abcf905cb4c391ea6b396

GIT_LFS_SKIP_SMUDGE=1 git clone \
  https://github.com/Ziems/arbor.git \
  "$target/gepa_artifact/utils/arbor"
git -C "$target/gepa_artifact/utils/arbor" checkout --detach \
  113fc35e05acbf2796a5917ec3b45ab44bfacd0b

(cd "$evidence_dir" && shasum -a 256 -c comparator-corrections.patch.sha256)
git -C "$target" apply "$evidence_dir/comparator-corrections.patch"

python3 -m unittest discover \
  -s "$target/tests" \
  -p 'test_corrected_comparator_harness.py' \
  -v

echo "corrected GEPA comparator checkout ready: $target"
