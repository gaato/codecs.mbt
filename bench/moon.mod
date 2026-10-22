// Unpublished. Benchmarks of the workspace's codecs, run with
// `moon bench --release`. Kept out of the published modules so that their
// test runs stay fast and their packages carry no benchmark data.

name = "gaato/codec_bench"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "native"

import {
  "gaato/zstd@0.3.1",
  "gaato/brotli@0.4.1",
  "gaato/deflate@0.1.0",
  "gaato/png@0.1.0",
  "moonbitlang/typst@0.1.7",
  "moonbitlang/x@0.5.6",
}
