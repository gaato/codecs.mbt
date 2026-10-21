// Apache-2.0. The upstream test frames under testdata/upstream are
// facebook/zstd's, under its BSD license; see NOTICE. Depends only on the
// workspace's contract modules, gaato/codec and gaato/codec_bytes.

name = "gaato/zstd"

version = "0.3.1"

license = "Apache-2.0"

readme = "src/README.mbt.md"

repository = "https://github.com/gaato/codecs.mbt"

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

import {
  "gaato/codec@0.1.0",
  "gaato/codec_bytes@0.1.1",
}
