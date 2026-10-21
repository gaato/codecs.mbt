///|
/// Outcome of one `Decoder::step` or `Encoder::step`: `Done`,
/// `NeedMoreInput` or `NeedMoreOutput`, and what an encoder's step is told
/// to do: `Continue`, `Flush` or `Finish`, as every `gaato/codec_bytes`
/// codec answers and is told.
pub using @codec_bytes {type Status, type EncodeAction}

///|
/// Why a step stopped early, inside the decoder.
priv suberror Stop {
  /// The header or the trailer needs bytes the input does not have yet.
  NeedInput
  /// The stream is refused.
  Fail(@codec.ErrorKind, String)
}

///|
/// The value of one of `@header`'s pure checks, or a refusal of `kind` with
/// its message.
fn[T] checked(
  result : Result[T, String],
  kind~ : @codec.ErrorKind = Corrupt,
) -> T raise Stop {
  match result {
    Ok(value) => value
    Err(message) => raise Fail(kind, message)
  }
}

///|
/// Whether `cmf` and `flg` are a valid zlib header: DEFLATE with a window of
/// at most 32 KiB and a correct header check. This is how a decoder tells a
/// zlib stream from raw DEFLATE when nothing else says which it is (HTTP's
/// `deflate` coding is zlib, yet some servers send raw DEFLATE): it is a
/// heuristic, though a strong one: the low four bits of CMF must be 8, which
/// in raw DEFLATE is a non-final stored block with a padding bit set, and
/// encoders write padding bits as zeros. Two random bytes pass about once in
/// a thousand (66 of the 65,536 pairs).
pub fn is_header(cmf : Byte, flg : Byte) -> Bool {
  @header.parse(cmf, flg) is Ok(_)
}
