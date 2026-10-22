// Apache-2.0. A streaming PNG decoder: one package at the root. It implements
// gaato/codec_image's contract, raises gaato/codec's errors, and holds a zlib
// decoder of gaato/deflate as a value for the image data.

name = "gaato/png"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [ "png", "apng", "image", "decoder", "streaming" ]

description = "A streaming PNG and APNG decoder for MoonBit: arbitrary input chunks, whole rows into bounded output slices, two rows of memory."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.0",
  "gaato/codec_image@0.1.0",
  "gaato/deflate@0.1.0",
}
