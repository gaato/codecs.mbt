// The contract of image decoders: types and a trait only, so that a decoder
// or a consumer depends on nothing else.

name = "gaato/codec_image"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [ "codec", "image", "streaming" ]

description = "The streaming contract of image decoders: step through input chunks, get whole rows into bounded output slices, with bounded memory."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.0",
}
