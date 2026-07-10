#!/usr/bin/env sh
set -eu

VENV_DIR="${DSEX_DSPY_VENV:-tmp/dspy-parity-venv}"
PYTHON="${PYTHON:-}"
RECREATE="${DSEX_DSPY_RECREATE:-}"

if [ -z "$PYTHON" ]; then
  for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON="$candidate"
      break
    fi
  done
fi

if [ -z "$PYTHON" ]; then
  echo "DSEx parity requires Python 3.10+ for current DSPy; no python3.10+ executable found." >&2
  exit 1
fi

"$PYTHON" - <<'PY'
import sys

if sys.version_info < (3, 10):
    raise SystemExit(
        f"DSEx parity requires Python 3.10+ for current DSPy; found {sys.version.split()[0]}"
    )
PY

if [ -x "$VENV_DIR/bin/python" ]; then
  if ! "$VENV_DIR/bin/python" - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
  then
    if [ "$VENV_DIR" = "tmp/dspy-parity-venv" ] || [ "$RECREATE" = "1" ]; then
      echo "Rebuilding stale DSPy parity venv at $VENV_DIR with $PYTHON"
      rm -rf "$VENV_DIR"
    else
      echo "$VENV_DIR uses Python older than 3.10. Set DSEX_DSPY_RECREATE=1 to rebuild it." >&2
      exit 1
    fi
  fi
fi

"$PYTHON" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install -U pip setuptools wheel
"$VENV_DIR/bin/python" -m pip install -U "dspy[optuna]==3.2.1" openai
"$VENV_DIR/bin/python" - <<'PY'
import dspy
import importlib.metadata

print("DSPy parity environment ready")
print("python:", importlib.metadata.version("pip"))
print("dspy:", getattr(dspy, "__version__", "unknown"))
print("has_gepa:", hasattr(dspy, "GEPA"))
print("has_react_v2:", hasattr(dspy, "ReActV2"))
PY
