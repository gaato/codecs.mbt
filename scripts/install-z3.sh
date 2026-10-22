#!/bin/sh
# Installs Z3 4.16.0, the solver of moon prove, into /opt (run as root, as in
# the CI and canary containers) and puts it on the PATH of the steps after it
# when GITHUB_PATH is set.
#
# The official release, pinned by checksum: other builds disagree with it (an
# openSUSE build proved a false goal; Debian's 4.13.3 fails a true one).
# scripts/prove.mbtx refuses any other version. Needs curl and unzip.
set -eu

release=z3-4.16.0
build=z3-4.16.0-x64-glibc-2.39
sha256=7288c49a5bd6dbafd7b0b0d1f65956b91672da24b08f09242919af159be3418e

zip=$(mktemp)
trap 'rm -f "$zip"' EXIT
curl -fsSL -o "$zip" "https://github.com/Z3Prover/z3/releases/download/$release/$build.zip"
echo "$sha256  $zip" | sha256sum -c -
unzip -q -o "$zip" -d /opt

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "/opt/$build/bin" >> "$GITHUB_PATH"
else
  echo "Z3 is in /opt/$build/bin; put it on PATH." >&2
fi
