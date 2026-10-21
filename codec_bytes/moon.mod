// The contract of byte-stream codecs: types and traits only, so that a codec
// or a consumer depends on nothing else.

name = "gaato/codec_bytes"

version = "0.1.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [ "codec", "compression", "streaming" ]

description = "The streaming contract of byte-stream codecs: step through input chunks into bounded output slices, with bounded memory."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.0",
}
