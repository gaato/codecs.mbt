# gaato/codec_harness

Unpublished. The checks every codec of the workspace is held to, run by the
private `conformance` module from outside the codecs, as a consumer of their
contracts would. Published modules never depend on it.

## How the checks see a codec

The checks are written once, against `Stepper`: given input, room for output
and whether the input ends there, take a step and say what was consumed,
what was produced and why the step stopped (`NeedMoreInput`,
`NeedMoreOutput`, an `Event`, or `Done`). Each kind of codec has an adapter
that turns its contract into this view and checks its own rules on the way;
`ByteDecoder` does it for `gaato/codec_bytes` decoders, and `ByteEncoder` for
its encoders. An encoder's step with `end` is a step with `Finish`, any other
a step with `Continue`, so every check below runs an encoder as it runs a
decoder, its output being the encoded stream. Both adapters check that a
step that raises reports nothing consumed or produced and that the counts fit
what the step was given; `ByteEncoder` also checks that `Done` comes only
after `Finish`, with all input consumed.

`drive` runs a codec over an input split by two `Sizes` sequences and checks
the rules every kind shares after every step: nothing is asked for after the
end, a full slice is really full, a step with room makes progress, memory
never passes its limit, and errors stick. Its
`Transcript` (output, events, error kind) is what two runs must agree on.

On top of `drive`: `check_splits` (every split agrees with the whole run),
`check_truncation` (prefixes end in `Truncated` or cleanly at a member
boundary), `check_trailing` (bytes after the end), `check_reset`, and `fuzz`
(corrupted inputs never break the contract; returns how often each outcome
happened).

For an encoder and a decoder of the same format: `check_roundtrip` encodes
an input whole and under every split, requires every encoding to equal the
whole one and to decode, with a fresh decoder, back to the input; and
`check_flush` encodes with a `Flush` at given offsets, and requires that a
fresh decoder given everything produced so far, without `end`, gives out
exactly the input up to each offset and asks for more. An encoder that cannot
flush raises `Unsupported` for `Flush`, and `check_flush` accepts that.

## Adding a kind

A kind whose output has structure maps it onto the same view. For an image
decoder that writes rows into the caller's buffer:

| Image decoder reports | Step as the checks see it |
|---|---|
| the header (size, pixel format) | `Event("header 640x480 rgba8")` |
| rows written into the buffer | `produced`: the rows' bytes |
| the buffer holds no further whole row | `NeedMoreOutput` |
| metadata it was asked for | `Event("metadata iCCP 3144")`, its bytes in `produced` |
| the end of a frame, of the image | `Event("frame end")`, then `Done` |

Room is in bytes for byte streams. A decoder that writes whole rows only
cannot fill an arbitrary number of bytes, so its adapter rounds the room it
is given up to whole rows; `NeedMoreOutput` then means "no room for another
row". With that, every check above applies unchanged: the same output bytes
and the same events whatever the split, truncation ends in `Truncated` after
whatever rows were complete, memory stays within the decoder's limit, and
errors stick. Interlaced images report their passes as events, and their
rows in pass order, so the transcript stays a single sequence.
