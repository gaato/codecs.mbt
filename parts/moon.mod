// Unpublished. The single source of the building blocks several formats
// share: scripts/gen_parts.mbtx copies the files scripts/modules.json lists
// into each format's module, under src/internal. A published module of parts
// would tie the formats together, since moon treats every 0.x version of a
// module as compatible with the others; copies keep each format's module
// self-contained (see README.md).

name = "gaato/codec_parts"

version = "0.0.0"

private = true

license = "Apache-2.0"

preferred_target = "native"
