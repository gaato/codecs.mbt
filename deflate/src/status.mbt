///|
/// Outcome of one `Decoder::step` or `Encoder::step`: `Done`,
/// `NeedMoreInput` or `NeedMoreOutput`, and what an encoder's step is told
/// to do: `Continue`, `Flush` or `Finish`, as every `gaato/codec_bytes`
/// codec answers and is told.
pub using @codec_bytes {type Status, type EncodeAction}
