#!/usr/bin/env bash
# Runs the repository validation suite. Usage: scripts/gates.sh [--no-js] [--no-wasm]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/modules.sh

skip_js=false
skip_wasm=false
for arg in "$@"; do
  case "$arg" in
    --no-js) skip_js=true ;;
    --no-wasm) skip_wasm=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
targets=(native)
$skip_js || targets+=(js)
$skip_wasm || targets+=(wasm wasm-gc)

run() { echo "+ $*"; "$@"; }

# Every module's CHANGELOG opens with [Unreleased] and has a heading for its version.
run scripts/release.sh check
for m in "${LEDGERED[@]}"; do
  # Every enforced limit in RESOURCE_BOUNDS.md names tests that exist.
  run scripts/bounds_check.sh "$m"
done
# The conformance suite's vectors are the current extract of each format's vectors.
run scripts/gen_conformance_vectors.py --check
run moon update
# From the workspace root, check and test cover every member.
for t in "${targets[@]}"; do
  run moon check --deny-warn --target "$t"
  MOON_CC="${MOON_CC:-cc}" run timeout 600 moon test --target "$t"
done
run moon fmt --check
run moon info
# Only meaningful in CI: in a jj working copy `git diff` compares against the parent change,
# so uncommitted edits would look stale. Set CHECK_MBTI=1 to enforce locally.
if [ "${CI:-}" = true ] || [ "${CHECK_MBTI:-}" = 1 ]; then
  git diff --exit-code -- '*.mbti' || { echo "pkg.generated.mbti is stale: run 'moon info' and commit" >&2; exit 1; }
fi
echo "gates: OK"
