# The workspace's modules, sourced by the other scripts.

# Published modules, bottom-up: a module comes after everything it imports.
MODULES=(codec codec_bytes zstd brotli)

# Modules that hold stream-sized state, with the ledgers that bound it
# (RESOURCE_BOUNDS.md, TEST_COVERAGE.md). The contract modules define types only.
LEDGERED=(zstd brotli)

# The sources each module's coverage ledger measures, as module-relative paths:
# the library and the internal packages it ships, not test-only packages.
declare -A COVERAGE_SCOPE=(
  [zstd]='^src/([^/]+|internal/(header|xxhash)/[^/]+)[.]mbt$'
  [brotli]='^src/([^/]+|internal/(huffman|lz77|rules)/[^/]+)[.]mbt$'
)
