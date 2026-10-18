#!/usr/bin/env bash
# Test-coverage report for gaato/zstd.
#
# Runs the native test suite with coverage instrumentation, writes a Coveralls
# JSON report, prints per-file and total tables, and checks every remaining
# uncovered file against the TEST_COVERAGE.md ledger: a file with uncovered
# lines must have a ledger row whose budget covers them.
#
# Usage: scripts/coverage_report.sh [--from-json FILE]
#   --from-json FILE  recheck an existing Coveralls JSON report against the
#                     ledger instead of re-running the instrumented tests.
#
# Exit status: 0 = every uncovered line is ledgered, 1 = unexplained coverage
# gaps or over-budget files, 2 = setup/run failure.
#
# Measurement pitfalls this script works around (see TEST_COVERAGE.md):
# - The reporter merges every `moonbit_coverage_*` counter file it is given or
#   finds; counters from earlier runs and trace maps of moved or deleted
#   packages corrupt the totals. Drop both before measuring, and pass the
#   trace maps and counters explicitly.
# - `-f summary` omits fully covered files; use the Coveralls JSON.
# - moon's bundled tcc cannot link on some hosts (openSUSE); use the system cc.

set -euo pipefail
# The tables use gawk's asorti; Debian's default awk (mawk) lacks it.
for tool in jq gawk; do
  command -v "$tool" >/dev/null || { echo "coverage_report.sh needs $tool" >&2; exit 2; }
done

# Measured sources, as module-relative paths (how the reporter names them):
# the library package and its XXH64, not the test-only checksum package under
# src/internal.
LIBRARY='^src/([^/]+|internal/xxhash/[^/]+)[.]mbt$'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ledger="$repo_root/TEST_COVERAGE.md"
json_file=""

if [[ "${1:-}" == "--from-json" ]]; then
  json_file="${2:?--from-json needs a file}"
else
  cd "$repo_root"
  json_file="$repo_root/_build/coverage_report.json"
  find _build -name 'moonbit_coverage_*' -delete 2>/dev/null || true
  rm -rf _build/native/debug/test
  MOON_CC="${MOON_CC:-cc}" moon test --target native --enable-coverage >/dev/null || {
    echo "error: instrumented native test run failed" >&2
    exit 2
  }
  traces=()
  while IFS= read -r f; do traces+=("$f"); done \
    < <(find _build/native/debug/test -name '*.trace.source')
  counters=()
  while IFS= read -r f; do counters+=(-t "$f"); done \
    < <(find _build -name 'moonbit_coverage_*')
  if [[ ${#traces[@]} -eq 0 || ${#counters[@]} -eq 0 ]]; then
    echo "error: no trace maps or counters after the instrumented run" >&2
    exit 2
  fi
  moon coverage report -- "${traces[@]}" "${counters[@]}" -f coveralls -o "$json_file" \
    >/dev/null 2>&1 || {
      echo "error: moon coverage report failed" >&2
      exit 2
    }
fi

# One "file<TAB>covered<TAB>total" line per measured source file.
jq -r --arg lib "$LIBRARY" '
  .source_files[]
  | select(.name | test($lib))
  | [ .name,
      ([.coverage[] | select(. != null and . > 0)] | length),
      ([.coverage[] | select(. != null)] | length) ]
  | @tsv
' "$json_file" | sort | gawk -F '\t' -v ledger="$ledger" -v lib="$LIBRARY" '
  # ---- ledger: rows like "| src/foo.mbt | 12 | reason |" -----------------
  BEGIN {
    while ((getline line < ledger) > 0) {
      if (line !~ /^\|/) continue
      split(line, cell, /\|/)
      file = cell[2]; gsub(/^ +| +$/, "", file)
      if (file !~ lib) continue
      budget_str = cell[3]; gsub(/^ +| +$/, "", budget_str)
      if (budget_str + 0 == budget_str) budget[file] = budget_str + 0
    }
    close(ledger)
  }

  {
    file = $1; cov = $2 + 0; tot = $3 + 0
    if (tot == 0) next   # declaration-only files have no executable points
    fcov[file] = cov; ftot[file] = tot
    lcov += cov; ltot += tot
    unc = tot - cov
    if (unc > 0) uncovered[file] = unc
    seen[file] = 1
  }

  END {
    printf "%-36s %11s %8s\n", "file", "covered", "%"
    n = asorti(fcov, keys)
    for (i = 1; i <= n; i++) {
      f = keys[i]
      printf "%-36s %5d/%-5d %7.1f%%\n", f, fcov[f], ftot[f], 100 * fcov[f] / ftot[f]
    }
    printf "%-36s %5d/%-5d %7.1f%%\n", "TOTAL", lcov, ltot, 100 * lcov / ltot
    print ""

    bad = 0
    n = asorti(uncovered, keys)
    for (i = 1; i <= n; i++) {
      f = keys[i]
      if (!(f in budget))
        { printf "UNEXPLAINED  %-32s %4d uncovered (no ledger row)\n", f, uncovered[f]; bad = 1 }
      else if (uncovered[f] > budget[f])
        { printf "OVER BUDGET  %-32s %4d uncovered > budget %d\n", f, uncovered[f], budget[f]; bad = 1 }
    }
    n = asorti(budget, keys)
    for (i = 1; i <= n; i++) {
      f = keys[i]
      if (!(f in seen))
        printf "STALE LEDGER %-32s file not in coverage output\n", f
      else if (!(f in uncovered))
        printf "STALE LEDGER %-32s fully covered; drop the row\n", f
      else if (uncovered[f] < budget[f])
        printf "note: budget slack %-21s %4d uncovered < budget %d\n", f, uncovered[f], budget[f]
    }
    if (bad) { print "\nledger check: FAIL"; exit 1 }
    print "ledger check: OK - every uncovered line is ledgered"
  }
'
