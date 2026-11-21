// Unpublished. Runs every codec of the workspace through the shared harness
// (gaato/codec_harness), from outside the codecs' modules, as a consumer of
// their contracts would.

name = "gaato/codec_conformance"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.2",
  "gaato/codec_bytes@0.1.3",
  "gaato/codec_harness@0.0.0",
  "gaato/zstd@0.6.1",
  "gaato/brotli@0.6.0",
  "gaato/deflate@0.4.1",
  "gaato/codec_image@0.1.1",
  "gaato/png@0.1.4",
  "gaato/snappy@0.1.1",
  "gaato/lz4@0.1.1",
  "gaato/lzw@0.1.1",
  "moonbitlang/typst@0.1.10",
}
