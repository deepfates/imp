#!/usr/bin/env sh
set -eu

DSPY_COMMIT="29448ae12756abdd14bd8796c819247ebb83673c"
DSPY_TAG="3.2.1"
TARGET="${IMP_DSPY_STABLE_SOURCE:-tmp/dspy-3.2.1}"
PYTHON="${PYTHON:-python3}"

if [ -e "$TARGET" ] && [ ! -d "$TARGET/.git" ]; then
  echo "Refusing to replace non-Git DSPy source target: $TARGET" >&2
  exit 1
fi

if [ -d "$TARGET/.git" ] &&
  { ! git -C "$TARGET" diff --quiet HEAD -- ||
    [ -n "$(git -C "$TARGET" ls-files --others --exclude-standard)" ]; }; then
  echo "Refusing to overwrite modified DSPy source target: $TARGET" >&2
  exit 1
fi

if [ ! -d "$TARGET/.git" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/stanfordnlp/dspy.git "$TARGET"
fi

git -C "$TARGET" fetch --filter=blob:none origin "$DSPY_COMMIT" "refs/tags/$DSPY_TAG:refs/tags/$DSPY_TAG"
git -C "$TARGET" checkout --detach "$DSPY_COMMIT"
"$PYTHON" scripts/verify_dspy_stable_source.py "$TARGET"
