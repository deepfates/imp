#!/usr/bin/env sh
set -eu

DSPY_VERSION="3.3.0b1"
TARGET="${IMP_DSPY_TARGET:-tmp/dspy-current-target}"
PYTHON="${PYTHON:-python3}"

valid_target() {
  "$PYTHON" - "$TARGET" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "dspy/predict/rlm.py": "ab9c28702bd02b2b88e324e36e6bcaadbaadae5b6e374fa7b3d3643706427ce8",
    "dspy/primitives/python_interpreter.py": "fef9baa19cd979e8466ef19e364e5f7e67848c9738955a2d3e1f0d7dae2177d4",
}
for name, wanted in expected.items():
    path = root / name
    actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "missing"
    if actual != wanted:
        raise SystemExit(1)
metadata = root / "dspy-3.3.0b1.dist-info" / "METADATA"
if not metadata.is_file() or "Version: 3.3.0b1\n" not in metadata.read_text():
    raise SystemExit(1)
PY
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

echo "DSPy $DSPY_VERSION source target is ready at $TARGET."
