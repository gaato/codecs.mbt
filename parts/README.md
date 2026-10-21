# gaato/codec_parts

Unpublished. The single source of the building blocks that several formats
share; each format's module carries copies of the files it uses.

| Package | Holds | Copied into |
| --- | --- | --- |
| `huffman` | Huffman code lengths and canonical codes for encoders, and `CodeMaker`, libdeflate's way of building length-limited codes; decoding tables (`Builder`) and their size bounds (`max_entries`) for decoders | brotli, deflate (`CodeMaker` deflate only) |
| `bits` | `BitPacker`, an encoder's least-significant-bit-first bit writer and output buffer | brotli |
| `lz77` | The hash and match length of LZ77 match finders; `Matcher`, a greedy one with bucketed hash chains; `HcMatchfinder` and `HtMatchfinder`, libdeflate's hash-chain and hash-table finders | brotli (`Matcher`), deflate (the other two) |
| `proof_bits` | The trusted bridges of `moon prove`: shifts and masks behind contracts that state their arithmetic, with the tests that back them | zstd, brotli, deflate |
| `proof_fields` | A lemma for proofs of header parsers: a bit field read with division and remainder is the field (apart from `proof_bits`, so that solvers prove it with nothing else in their context) | zstd |
| `proof_controls` | Negative controls for `moon prove`: false claims that every solver must refuse (`scripts/prove.mbtx`) | none |

## Why copies

A module's version covers all of its packages, and moon's resolver treats
every 0.x version of a module as compatible with the others. A published
parts module would couple the formats: a change one format needs would be
picked up by every other format's users. Copies keep each format's module
standalone, with its own version and tests, while the code has one source.

## Working on a part

- Edit the files here, never the copies: each copy starts with a line saying
  where it comes from.
- `moon test --target native parts/huffman parts/bits parts/lz77` runs the
  parts' tests where they live.
- `moon run scripts/gen_parts.mbtx` regenerates the copies;
  `moon run scripts/gen_parts.mbtx -- --check` (part of the gates) fails when a
  copy differs from its source.

What a module copies is the `copies` object of `scripts/modules.json`: per
module, per package, the files, tests included. Files rather than whole
packages, so that a module carries, and its coverage ledger covers, only what
it uses. The copies go to `<module>/src/internal/<package>`; add that
directory to the module's `coverage_scope` too.

The generator writes each copy's `moon.pkg` from the part's, with imports of
other parts rewritten to the module's copies of them, so a module that copies
a part must also copy the parts it imports. It does not copy
`pkg.generated.mbti`, which names the package; `moon info` writes the copy's.

Keep tests next to the code they test, in the same package, so that they are
copied along: a format's tests then cover its copies.
