#!/usr/bin/env sh
set -eu

DSPY_CURRENT_VERSION="3.3.1"
GEPA_COMMIT="8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"
DENO_VERSION="2.8.3"
DSPY_PYTHON="${IMP_DSPY_PYTHON:-${PYTHON:-python3.12}}"
DSPY_VENV="${IMP_DSPY_CURRENT_VENV:-tmp/dspy-current-venv}"
DSPY_LOCK="benchmarks/requirements-dspy-rlm.lock"
GEPA_ROOT="${IMP_GEPA_CURRENT_ROOT:-tmp/gepa-current}"

if ! command -v deno >/dev/null 2>&1; then
  echo "Deno $DENO_VERSION is required by the pinned DSPy RLM runtime." >&2
  exit 1
fi

installed_deno_version="$(deno --version | sed -n '1s/^deno \([^ ]*\).*/\1/p')"
if [ "$installed_deno_version" != "$DENO_VERSION" ]; then
  echo "Deno $DENO_VERSION is required; found ${installed_deno_version:-unknown}." >&2
  exit 1
fi

scripts/setup_dspy_stable_source.sh
scripts/setup_dspy_current_target.sh

if command -v uv >/dev/null 2>&1; then
  uv venv --clear --python "$DSPY_PYTHON" "$DSPY_VENV"
  uv pip sync --python "$DSPY_VENV/bin/python" "$DSPY_LOCK"
else
  "$DSPY_PYTHON" -m venv --clear "$DSPY_VENV"
  "$DSPY_VENV/bin/python" -m pip install --disable-pip-version-check -r "$DSPY_LOCK"
fi

installed_dspy_version="$($DSPY_VENV/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("dspy"))')"
if [ "$installed_dspy_version" != "$DSPY_CURRENT_VERSION" ]; then
  echo "DSPy $DSPY_CURRENT_VERSION is required; found $installed_dspy_version." >&2
  exit 1
fi

if [ -d "$GEPA_ROOT/.git" ] &&
  { ! git -C "$GEPA_ROOT" diff --quiet HEAD -- ||
    [ -n "$(git -C "$GEPA_ROOT" ls-files --others --exclude-standard)" ]; }; then
  echo "Rebuilding modified generated GEPA checkout at $GEPA_ROOT"
  rm -rf "$GEPA_ROOT"
fi

if [ ! -d "$GEPA_ROOT/.git" ]; then
  rm -rf "$GEPA_ROOT"
  GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none \
    https://github.com/gepa-ai/gepa.git "$GEPA_ROOT"
fi

git -C "$GEPA_ROOT" fetch --filter=blob:none origin "$GEPA_COMMIT"
GIT_LFS_SKIP_SMUDGE=1 git -C "$GEPA_ROOT" checkout --detach "$GEPA_COMMIT"

echo "Pinned Deno, DSPy, and GEPA reference environments are ready."
