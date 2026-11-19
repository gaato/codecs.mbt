// The one-shot calls (`compress`, `decompress`) run a streaming encoder or
// decoder over the whole input. They used to take its output 64 KiB at a
// time and append each piece to a Buffer: three copies of every byte, and
// on JS each a loop that checks every index. Here the output goes straight
// into one array that doubles when it fills, and is copied once at the end
// (not at all when it is full).
// Decoding the benchmarks' text with gaato/deflate's `decompress` went from
// 9.1 to 4.8 ms on JS (bench/, 2026-11-19).

///|
/// Runs `step` over all of `input` and returns everything it wrote. Each
/// call of `step(rest, room)` is one step of a decoder over what is left of
/// the input, with `end=true`, writing into `room`: it returns how many bytes
/// it consumed, how many it produced, and whether it is done. `max_output`
/// caps the output (unlimited by default): past it, `LimitExceeded({
/// resource: Output, .. })` is raised, with `max_output` (0 for a negative
/// one) as the limit.
pub fn decode(
  input : BytesView,
  max_output? : Int32,
  step : (BytesView, MutArrayView[Byte]) -> (Int32, Int32, Bool) raise @codec.CodecError,
) -> Bytes raise @codec.CodecError {
  // One byte past the limit is room enough to see the output go past it.
  let cap = match max_output {
    Some(limit) if limit < MAX_LENGTH => limit.max(0) + 1
    _ => MAX_LENGTH
  }
  let (out, n, done) = run(
    input,
    initial_decode(input.length()).min(cap),
    cap,
    step,
  )
  // Short of done, the output reached `cap`: one byte past the limit, or the
  // longest array.
  if !done || n == cap {
    let limit = match max_output {
      Some(limit) => limit.max(0)
      None => MAX_LENGTH
    }
    raise @codec.CodecError(
      LimitExceeded({
        resource: Output,
        needed: None,
        limit: limit.to_uint64(),
      }),
      "the output exceeds \{limit} bytes",
    )
  }
  take(out, n)
}

///|
/// Runs `step` over all of `input`, as `decode` does, for an encoder: each
/// call is one step with `action=Finish`. It raises what `step` raises.
pub fn encode(
  input : BytesView,
  step : (BytesView, MutArrayView[Byte]) -> (Int32, Int32, Bool) raise?,
) -> Bytes raise? {
  let (out, n, done) = run(
    input,
    initial_encode(input.length()),
    MAX_LENGTH,
    step,
  )
  guard done else { abort("encode: the output exceeds \{MAX_LENGTH} bytes") }
  take(out, n)
}

///|
/// The longest array: `Int32`'s largest value.
const MAX_LENGTH : Int32 = 0x7FFFFFFF

///|
/// The output array's first size for a decoder: four times the input, as
/// most compressed data expands by less, between 4 KiB and 16 MiB.
fn initial_decode(n : Int32) -> Int32 {
  (n.to_int64() * 4).clamp(min=4096L, max=16777216L).to_int()
}

///|
/// The output array's first size for an encoder: half the input, between
/// 4 KiB and 16 MiB.
fn initial_encode(n : Int32) -> Int32 {
  (n / 2).clamp(min=4096, max=16777216)
}

///|
/// The loop of `decode` and `encode`: steps until done, or until the output
/// reaches `cap` with the step not done. Returns the array, the length
/// written and whether the step is done.
fn run(
  input : BytesView,
  initial : Int32,
  cap : Int32,
  step : (BytesView, MutArrayView[Byte]) -> (Int32, Int32, Bool) raise?,
) -> (FixedArray[Byte], Int32, Bool) raise? {
  let mut out = FixedArray::make(initial, b'\x00')
  let mut n = 0
  let mut rest = input
  for ;; {
    if n == out.length() {
      if n == cap {
        return (out, n, false)
      }
      // Doubling, up to `cap`, without overflowing.
      let grown = FixedArray::make(
        (n.to_int64() * 2).min(cap.to_int64()).to_int(),
        b'\x00',
      )
      copy(grown, out, n)
      out = grown
    }
    let (consumed, produced, done) = step(
      rest,
      out.unsafe_mut_view(start=n, end=out.length()),
    )
    rest = rest[consumed:]
    n += produced
    if done {
      return (out, n, true)
    }
  }
}

///|
/// The first `n` bytes of `out`, which the caller does not use again: `out`
/// itself when it is full, else a copy (on JS without core's checked copy).
pub fn take(out : FixedArray[Byte], n : Int32) -> Bytes {
  if n == out.length() {
    return out.unsafe_reinterpret_as_bytes()
  }
  let exact = FixedArray::make(n, b'\x00')
  copy(exact, out, n)
  exact.unsafe_reinterpret_as_bytes()
}

///|
/// Copies `src[0:n]` to `dst[0:n]`: one block move.
#cfg(not(target="js"))
fn copy(dst : FixedArray[Byte], src : FixedArray[Byte], n : Int32) -> Unit {
  FixedArray::unsafe_blit(dst, 0, src, 0, n)
}

///|
/// Copies `src[0:n]` to `dst[0:n]`: on JS a loop without index checks, where
/// core's copies check every index (a tenth of decoding with each format's
/// `decompress`, bench/, 2026-11-19).
#cfg(target="js")
fn copy(dst : FixedArray[Byte], src : FixedArray[Byte], n : Int32) -> Unit {
  for i in 0..<n {
    dst.unsafe_set(i, src.unsafe_get(i))
  }
}
