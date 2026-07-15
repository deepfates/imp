#!/usr/bin/env sh
set -eu

DSPY_VERSION="3.3.0b1"
TARGET="${IMP_DSPY_TARGET:-tmp/dspy-current-target}"
PYTHON="${PYTHON:-python3}"

valid_target() {
  "$PYTHON" scripts/verify_dspy_current_target.py "$TARGET" >/dev/null
}

if valid_target 2>/dev/null; then
  echo "DSPy $DSPY_VERSION source target is ready at $TARGET."
  exit 0
fi

rm -rf "$TARGET"
if command -v uv >/dev/null 2>&1; then
  uv pip install --target "$TARGET" --no-deps "dspy==$DSPY_VERSION"
else
  "$PYTHON" -m pip install --disable-pip-version-check \
    --target "$TARGET" --no-deps "dspy==$DSPY_VERSION"
fi

if ! valid_target; then
  echo "DSPy $DSPY_VERSION source target failed its pinned source audit." >&2
  exit 1
fi

"$PYTHON" scripts/verify_dspy_current_target.py "$TARGET"
