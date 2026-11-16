// LZW in the flavours files use it in: GIF's, TIFF's, PDF's and the .Z of
// Unix compress; a decoder and an encoder, streaming.

name = "gaato/lzw"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [ "lzw", "gif", "tiff", "compress", "codec" ]

description = "LZW as GIF, TIFF, PDF and Unix compress (.Z) use it: a streaming decoder and encoder."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.1",
  "gaato/codec_bytes@0.1.2",
}
