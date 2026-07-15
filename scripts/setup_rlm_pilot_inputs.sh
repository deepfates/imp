#!/usr/bin/env sh
set -eu

DSPY_VERSION="3.3.0b1"
DSPY_TARGET="tmp/dspy-current-target"
DSPY_VENV="tmp/dspy-current-venv"
RLM_COMMIT="72d6940142ddfb84ee6be573dc999a37e633e671"
RLM_TARGET="tmp/rlm-upstream"
PAPER_PATH="tmp/pdfs/rlm-2512.24601v3.pdf"
PAPER_URL="https://arxiv.org/pdf/2512.24601v3"
PAPER_SHA256="8567362c22768d9b50d4a4a8d63bb28dda2c2b2051be30d67f70f645170429ca"

if [ ! -x "$DSPY_VENV/bin/python" ]; then
  echo "Run scripts/setup_reference_test_env.sh first." >&2
  exit 1
fi

python_version="$($DSPY_VENV/bin/python --version 2>&1)"
if [ "$python_version" != "Python 3.13.12" ]; then
  echo "Python 3.13.12 is required for artifact reproduction; found ${python_version:-unknown}." >&2
  exit 1
fi

download_verified() {
  url="$1"
  destination="$2"
  expected="$3"
  "$DSPY_VENV/bin/python" - "$url" "$destination" "$expected" <<'PY'
import hashlib
import os
import pathlib
import sys
import urllib.request

url, destination, expected = sys.argv[1:]
path = pathlib.Path(destination)
if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
    raise SystemExit
path.parent.mkdir(parents=True, exist_ok=True)
partial = path.with_suffix(path.suffix + ".partial")
partial.unlink(missing_ok=True)
request = urllib.request.Request(url, headers={"User-Agent": "imp-evidence/1"})
try:
    with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())
    actual = hashlib.sha256(partial.read_bytes()).hexdigest()
    if actual != expected:
        raise RuntimeError(f"digest mismatch for {destination}: expected {expected}, got {actual}")
    os.replace(partial, path)
finally:
    partial.unlink(missing_ok=True)
PY
}

download_verified "$PAPER_URL" "$PAPER_PATH" "$PAPER_SHA256"

if [ -d "$RLM_TARGET/.git" ] &&
  { ! git -C "$RLM_TARGET" diff --quiet HEAD -- ||
    [ -n "$(git -C "$RLM_TARGET" ls-files --others --exclude-standard)" ]; }; then
  echo "Refusing to replace modified RLM authority checkout at $RLM_TARGET." >&2
  exit 1
fi
if [ ! -d "$RLM_TARGET/.git" ]; then
  rm -rf "$RLM_TARGET"
  git clone --filter=blob:none https://github.com/alexzhang13/rlm.git "$RLM_TARGET"
fi
git -C "$RLM_TARGET" fetch --filter=blob:none origin "$RLM_COMMIT"
git -C "$RLM_TARGET" checkout --detach "$RLM_COMMIT"

if [ ! -f "$DSPY_TARGET/dspy/predict/rlm.py" ]; then
  rm -rf "$DSPY_TARGET"
  if command -v uv >/dev/null 2>&1; then
    uv pip install --target "$DSPY_TARGET" --no-deps "dspy==$DSPY_VERSION"
  else
    "$DSPY_VENV/bin/python" -m pip install --disable-pip-version-check \
      --target "$DSPY_TARGET" --no-deps "dspy==$DSPY_VERSION"
  fi
fi

"$DSPY_VENV/bin/python" benchmarks/data/rlm/fetch.py --family oolong_pairs

"$DSPY_VENV/bin/python" - <<'PY'
import hashlib
import pathlib

expected = {
    "tmp/pdfs/rlm-2512.24601v3.pdf": "8567362c22768d9b50d4a4a8d63bb28dda2c2b2051be30d67f70f645170429ca",
    "tmp/rlm-upstream/rlm/core/rlm.py": "f7df6af55027159b2f428ff98c9b19beb872618ee88aa8fef62c9498fa1e0562",
    "tmp/rlm-upstream/rlm/utils/prompts.py": "579c8ef220739f691d3896257b8289eec7e7b634fe473f41dea4adb83560b47e",
    "tmp/dspy-current-target/dspy/predict/rlm.py": "ab9c28702bd02b2b88e324e36e6bcaadbaadae5b6e374fa7b3d3643706427ce8",
    "tmp/dspy-current-target/dspy/primitives/python_interpreter.py": "fef9baa19cd979e8466ef19e364e5f7e67848c9738955a2d3e1f0d7dae2177d4",
    "benchmarks/data/rlm/oolong_pairs_trec_coarse.jsonl": "11b58e289d19152c3e6fa80f347e250021a6fe25f181925bac8e4e4ca2a4d4cc",
}
for name, wanted in expected.items():
    path = pathlib.Path(name)
    actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "missing"
    if actual != wanted:
        raise RuntimeError(f"digest mismatch for {name}: expected {wanted}, got {actual}")
print("Pinned RLM pilot authorities and dataset are ready.")
PY
