// Apache-2.0. The upstream test frames under testdata/upstream are
// facebook/zstd's, under its BSD license; see NOTICE. No dependencies beyond
// moonbitlang/core.

name = "gaato/zstd"

version = "0.1.0"

license = "Apache-2.0"

readme = "src/README.mbt.md"

repository = "https://github.com/gaato/zstd.mbt"

keywords = [
  "zstd",
  "zstandard",
  "compression",
  "decompression",
  "rfc8878",
  "streaming",
]

description = "A streaming Zstandard (RFC 8878) decoder in pure MoonBit: arbitrary input chunks, bounded output slices, memory bounded by the window."

source = "src"

preferred_target = "native"
