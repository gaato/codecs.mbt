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
  "gaato/codec@0.1.2",
  "gaato/codec_bytes@0.1.3",
  "gaato/codec_harness@0.0.0",
  "gaato/zstd@0.6.1",
  "gaato/brotli@0.6.0",
  "gaato/deflate@0.4.1",
  "gaato/png@0.1.4",
  "gaato/snappy@0.1.1",
  "gaato/lz4@0.1.1",
  "gaato/lzw@0.1.1",
  "moonbitlang/typst@0.1.10",
  "gmlewis/image@0.17.20",
  "gmlewis/io@0.23.22",
  "mizchi/image@0.5.0",
  "moonbitlang/x@0.5.8",
  "Milky2018/zstd@0.1.4",
  "hustcer/fbr@0.8.2",
  "mizchi/brotli@0.2.2",
  "moonbit-community/flate@0.10.0",
  "gmlewis/flate@0.36.19",
  "gmlewis/gzip@0.34.19",
  "gmlewis/zlib@0.21.19",
  "mizchi/zlib@0.4.12",
  "hustcer/fzip@0.8.8",
  "moonbitstack/moonzip@0.4.1",
}
