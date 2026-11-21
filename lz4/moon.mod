// LZ4: its frame format, streamed, with its checksums, skippable frames and
// legacy frames, and its block format, whole; the encoder is lz4's fast one,
// whose compressor follows lz4's under the license in LICENSE-lz4.

name = "gaato/lz4"

version = "0.1.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [ "lz4", "compression", "streaming", "codec" ]

description = "LZ4's frame and block formats: a streaming decoder and encoder for frames, with XXH32 checks, dictionaries, skippable and legacy frames."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.2",
  "gaato/codec_bytes@0.1.3",
}
