// Apache-2.0, except the static dictionary data in src/static_data.mbt,
// which is google/brotli's c/common/dictionary.bin under the MIT license
// (Copyright (c) 2009, 2010, 2013-2016 by the Brotli Authors); its notice is
// in LICENSE-dictionary. Depends only on gaato/codec and gaato/codec_bytes,
// the workspace's shared error types and byte-stream contract.

name = "gaato/brotli"

version = "0.4.0"

license = "Apache-2.0"

readme = "src/README.mbt.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [
  "brotli",
  "compression",
  "decompression",
  "encoder",
  "rfc7932",
  "streaming",
]

description = "A streaming Brotli (RFC 7932) decoder and encoder in pure MoonBit: arbitrary input chunks, bounded output slices, memory bounded by the window."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.0",
  "gaato/codec_bytes@0.1.0",
}
