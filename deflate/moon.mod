// Apache-2.0. Three packages: raw DEFLATE (RFC 1951) at the root, and the zlib
// (RFC 1950) and gzip (RFC 1952) formats in deflate/zlib and deflate/gzip,
// which hold a raw decoder or encoder as a value. The raw decoding and encoding
// are built today on moonbit-community/flate's inflater and deflater
// (Apache-2.0), which no public signature names, so that an implementation of
// this module's own can replace them without a breaking change. Depends otherwise only on the workspace's contract
// modules, gaato/codec and gaato/codec_bytes.

name = "gaato/deflate"

version = "0.1.0"

license = "Apache-2.0"

readme = "src/README.mbt.md"

repository = "https://github.com/gaato/codecs.mbt"

keywords = [
  "deflate",
  "inflate",
  "zlib",
  "gzip",
  "decompression",
  "compression",
  "rfc1951",
  "rfc1950",
  "rfc1952",
  "streaming",
]

description = "Streaming DEFLATE, zlib and gzip decoders and encoders (RFC 1951, 1950, 1952) for MoonBit: arbitrary input chunks, bounded output slices, checksums verified, gzip headers and members, zlib preset dictionaries, levels 0 to 9 and sync flush."

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.0",
  "gaato/codec_bytes@0.1.1",
  "moonbit-community/flate@0.9.0",
}
