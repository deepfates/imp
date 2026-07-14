#!/usr/bin/env sh
set -eu

DSPY_CURRENT_VERSION="3.3.0b1"
GEPA_COMMIT="cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
PYTHON="${PYTHON:-python3}"

PYTHON="$PYTHON" scripts/setup_dspy_parity_env.sh

rm -rf tmp/dspy-current-target
"$PYTHON" -m pip install \
  --disable-pip-version-check \
  --target tmp/dspy-current-target \
  --no-deps \
  "dspy==$DSPY_CURRENT_VERSION"

if [ ! -d tmp/gepa-artifact/.git ]; then
  rm -rf tmp/gepa-artifact
  GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none \
    https://github.com/gepa-ai/gepa-artifact.git tmp/gepa-artifact
fi

git -C tmp/gepa-artifact fetch --filter=blob:none origin "$GEPA_COMMIT"
GIT_LFS_SKIP_SMUDGE=1 git -C tmp/gepa-artifact checkout --detach "$GEPA_COMMIT"

echo "Pinned DSPy and GEPA reference environments are ready."
