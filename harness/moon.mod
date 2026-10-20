// Unpublished. The checks every codec of the workspace is held to, written
// against the kinds' contracts so that one harness serves every codec. Kept
// out of the published modules' dependency graphs: tests import it from
// the private conformance module.

name = "gaato/codec_harness"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "native"

import {
  "gaato/codec@0.1.0",
  "gaato/codec_bytes@0.1.0",
}
