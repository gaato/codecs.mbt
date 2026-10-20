# The workspace's modules, sourced by the other scripts.

# Published modules, bottom-up: a module comes after everything it imports.
MODULES=(zstd brotli)

# The sources each module's coverage ledger measures, as module-relative paths:
# the library and the internal packages it ships, not test-only packages.
declare -A COVERAGE_SCOPE=(
  [zstd]='^src/([^/]+|internal/xxhash/[^/]+)[.]mbt$'
  [brotli]='^src/([^/]+|internal/(huffman|lz77)/[^/]+)[.]mbt$'
)
