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
  "gaato/codec@0.1.0",
  "gaato/codec_bytes@0.1.1",
  "gaato/codec_harness@0.0.0",
  "gaato/zstd@0.3.1",
  "gaato/brotli@0.4.1",
  "gaato/deflate@0.1.0",
  "gaato/codec_image@0.1.0",
  "gaato/png@0.1.0",
  "moonbitlang/typst@0.1.7",
}
