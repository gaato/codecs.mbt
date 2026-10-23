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
  "gaato/codec@0.1.0",
  "gaato/codec_bytes@0.1.1",
  "gaato/codec_harness@0.0.0",
  "gaato/zstd@0.3.1",
  "gaato/brotli@0.4.1",
  "gaato/deflate@0.1.0",
  "gaato/png@0.1.0",
  "moonbitlang/typst@0.1.9",
  "gmlewis/image@0.17.18",
  "gmlewis/io@0.23.20",
  "mizchi/image@0.4.3",
  "moonbitlang/x@0.5.6",
  "moonbitlang/async@0.22.5",
  "Milky2018/zstd@0.1.4",
  "hustcer/fbr@0.8.2",
  "mizchi/brotli@0.2.2",
  "moonbit-community/flate@0.10.0",
  "gmlewis/flate@0.36.17",
  "gmlewis/gzip@0.34.17",
  "gmlewis/zlib@0.21.17",
  "mizchi/zlib@0.4.10",
  "hustcer/fzip@0.8.8",
}
