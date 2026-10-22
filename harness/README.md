# gaato/codec_harness

Unpublished. The checks every codec of the workspace is held to, run by the
private `conformance` module from outside the codecs, as a consumer of their
contracts would. Published modules never depend on it.

## How the checks see a codec

The checks are written once, against `Stepper`: given input, room for output
and whether the input ends there, take a step and say what was consumed,
what was produced and why the step stopped (`NeedMoreInput`,
`NeedMoreOutput`, an `Event`, `Wrote`, `Done`, or `Raised` with the kind and
message of a codec error). Each kind of codec has an adapter
that turns its contract into this view and checks its own rules on the way;
`ByteDecoder` does it for `gaato/codec_bytes` decoders, `ByteEncoder` for
its encoders, and `ImageDecoder` for `gaato/codec_image` decoders (see
"Image decoders" below). An encoder's step with `end` is a step with
`Finish`, any other a step with `Continue`, so every check below runs an
encoder as it runs a decoder, its output being the encoded stream. The
adapters check that the counts of every step, one that raises included, fit
what the step was given, and keep what a step that raises produced; that a
full slice is really full, since only the adapter knows the unit of output
(`ByteDecoder` and `ByteEncoder`: `NeedMoreOutput` filled the room); and
`ByteEncoder` also checks that `Done` comes only after `Finish`, with all
input consumed.

`drive` runs a codec over an input split by two `Sizes` sequences and checks
the rules every kind shares after every step: nothing is asked for after the
end, a step with room makes progress, memory never passes its limit, and
errors stick: the step after one raises the same kind and reports nothing
consumed or produced. `Wrote` is a step that wrote output and stopped for no
reason the checks compare: `drive` keeps its bytes and goes on. Its
`Transcript` (output, the output before an error included, events, error
kind) is what two runs must agree on; the message and, after an error, the
input consumed are kept but not compared.

On top of `drive`: `check_splits` (every split of a valid stream agrees with
the whole run), `check_error_splits` (the same for an input that may be
corrupt: whole, two random splits, and a byte at a time each way for small
inputs, all with the same output before the same kind of error),
`check_truncation` (prefixes end in `Truncated` or cleanly at a member
boundary), `check_trailing` (bytes after the end: `TrailingData` given at
once has consumed exactly the stream and written all its output),
`check_reset`, and `fuzz` (corrupted inputs never break the contract, each
under `check_error_splits`; returns how often each outcome happened).

For an encoder and a decoder of the same format: `check_roundtrip` encodes
an input whole and under every split, requires every encoding to equal the
whole one and to decode, with a fresh decoder, back to the input; and
`check_flush` encodes with a `Flush` at given offsets, and requires that a
fresh decoder given everything produced so far, without `end`, gives out
exactly the input up to each offset and asks for more. An encoder that cannot
flush raises `Unsupported` for `Flush`, and `check_flush` accepts that.

## Image decoders

`ImageDecoder` turns a `gaato/codec_image` decoder into a `Stepper`, so that
`drive` and every check built on it run image decoders as they run byte
streams:

| The image decoder answers | The step as the checks see it |
|---|---|
| `Header` | `Event("header 640x480")`, followed by what the format's describer adds (`"header 640x480 rgba8"`) |
| `Frame` | `Event("frame 0,0 640x480")`, with the describer's text |
| `Rows`, the first of a pass | `Event("pass 1 at 4,0 by 8,8")`, the rows' bytes in `produced` |
| `Rows`, any other | `Wrote`, the rows' bytes in `produced` |
| `Metadata` | `Event("metadata 3144")`, with the describer's text (`"metadata 3144 iCCP"`), its bytes in `produced` |
| `FrameEnd` | `Event("frame end")` |
| `Done`, `NeedMoreInput`, `NeedMoreOutput` | the same |
| an error | `Raised` with its kind and message |

How many rows one step carries depends on the room, so it is not part of the
transcript. The transcript of a run is then the rows and the blocks of
metadata, one after another, and the events with the values their accessors
reported: the same for every split, or the decoder broke rule 5 of the image
contract (CONTRACT.md, "Images").

Room is in bytes. A decoder that writes whole rows cannot fill an arbitrary
number of bytes, so the adapter rounds the room it is given up to whole
units: to a multiple of the decoder's `room_needed`, when it is known, or
leaves it as it is. A room of 1 is then one row a step, and 65,536 is as
many rows as fit. Every split of `splits()` thus runs an image decoder with
its output cut into whole rows in several ways, down to one row a step,
besides its input cut down to one byte a step. A full slice is one whose
room is shorter than `room_needed`.

On every step, `ImageDecoder` also checks the image rules that do not
depend on the split:

- the counts fit what the step was given, as for byte streams; only `Rows`
  and `Metadata` write, and a step that raises writes nothing;
- `Rows` wrote `rows_count * row_bytes` bytes, at least one row of at least
  one byte, and the lattice and `row_bytes` stay the same through a pass;
- `Header` comes once, before any `Frame`; `Rows` come only inside a frame;
  `Done` never inside one, and never before `Header`;
- every frame lies inside the canvas, and every pass's lattice starts
  inside the frame, with steps of at least 1;
- passes come in increasing order, each from row 0 without gaps, and a
  pass that is left is complete: it gave the number of rows its lattice
  and the frame's height make;
- `FrameEnd` comes after the last pass reported has given all its rows.

With these, every check above applies to images unchanged: the same rows,
blocks and events, then the same kind of error, under every split of input
and output; truncation ends in `Truncated` after whatever rows were
complete; bytes after the image raise `TrailingData` with the image
consumed exactly; `check_member` stops right after the image; memory stays
within the decoder's limit after every step; errors stick.

`describe` is how a format adds what the contract does not know: the pixel
layout to the header (`"rgba8"`, `"palette 4"`), whether a frame is part of
the animation and its timing, a block's chunk type. The tests of a format
pass its own describer, so that a decoder that reports a wrong layout or a
wrong chunk type under some split fails rule 5 too.

The adapter's own tests (`src/image_test.mbt`) run it over a toy image
decoder that keeps the contract, under every check, and over variants that
break it, which the adapter must catch.
