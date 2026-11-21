// Snappy: its raw format, whole, and its framing format, streamed, with
// CRC-32C checks; its raw streams are what Google's snappy writes.

name = "gaato/snappy"

version = "0.1.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [ "snappy", "compression", "streaming", "codec" ]

description = "Snappy's raw and framing formats: a decoder and an encoder, streaming for the framing format, with CRC-32C checks."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.2",
  "gaato/codec_bytes@0.1.3",
}
