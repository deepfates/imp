#!/usr/bin/env sh
set -eu

DSPY_CURRENT_VERSION="3.3.0b1"
GEPA_COMMIT="cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
DENO_VERSION="2.8.3"
DSPY_PYTHON="${IMP_DSPY_PYTHON:-python3.13}"
DSPY_VENV="${IMP_DSPY_CURRENT_VENV:-tmp/dspy-current-venv}"
DSPY_LOCK="benchmarks/requirements-dspy-rlm.lock"

if ! command -v deno >/dev/null 2>&1; then
  echo "Deno $DENO_VERSION is required by the pinned DSPy RLM runtime." >&2
  exit 1
fi

installed_deno_version="$(deno --version | sed -n '1s/^deno \([^ ]*\).*/\1/p')"
if [ "$installed_deno_version" != "$DENO_VERSION" ]; then
  echo "Deno $DENO_VERSION is required; found ${installed_deno_version:-unknown}." >&2
  exit 1
fi

command -v uv >/dev/null 2>&1 || {
  echo "uv is required to create the pinned DSPy RLM environment." >&2
  exit 1
}

uv venv --clear --python "$DSPY_PYTHON" "$DSPY_VENV"
uv pip sync --python "$DSPY_VENV/bin/python" "$DSPY_LOCK"

installed_dspy_version="$($DSPY_VENV/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("dspy"))')"
if [ "$installed_dspy_version" != "$DSPY_CURRENT_VERSION" ]; then
  echo "DSPy $DSPY_CURRENT_VERSION is required; found $installed_dspy_version." >&2
  exit 1
fi

if [ -d tmp/gepa-artifact/.git ] &&
  { ! git -C tmp/gepa-artifact diff --quiet HEAD -- ||
    [ -n "$(git -C tmp/gepa-artifact ls-files --others --exclude-standard)" ]; }; then
  echo "Rebuilding modified generated GEPA checkout at tmp/gepa-artifact"
  rm -rf tmp/gepa-artifact
fi

if [ ! -d tmp/gepa-artifact/.git ]; then
  rm -rf tmp/gepa-artifact
  GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none \
    https://github.com/gepa-ai/gepa-artifact.git tmp/gepa-artifact
fi

git -C tmp/gepa-artifact fetch --filter=blob:none origin "$GEPA_COMMIT"
GIT_LFS_SKIP_SMUDGE=1 git -C tmp/gepa-artifact checkout --detach "$GEPA_COMMIT"

echo "Pinned Deno, DSPy, and GEPA reference environments are ready."
