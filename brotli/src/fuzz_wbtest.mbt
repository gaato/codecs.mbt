///|
/// `input` with a seeded corruption: bit flips, a replaced, inserted or
/// dropped byte, or a truncation.
fn mutate(input : Bytes, rng : Rng) -> Bytes {
  let bytes = input.to_array()
  match rng.below(5) {
    0 =>
      for _ in 0..<(1 + rng.below(4)) {
        let i = rng.below(bytes.length())
        bytes[i] = bytes[i] ^ (1 << rng.below(8)).to_byte()
      }
    1 => bytes[rng.below(bytes.length())] = rng.below(256).to_byte()
    2 => bytes.insert(rng.below(bytes.length() + 1), rng.below(256).to_byte())
    3 => bytes.remove(rng.below(bytes.length())) |> ignore
    _ => bytes.truncate(rng.below(bytes.length()))
  }
  Bytes::from_array(bytes)
}

///|
test "corrupted streams raise errors or decode, within bounds, never abort" {
  let rng = Rng::new(20260418)
  let sources = vectors.filter(v => v.size <= 300000).map(v => v.input())
  let tally : Map[String, Int32] = Map([])
  for _ in 0..<2000 {
    let source = sources[rng.below(sources.length())]
    guard source.length() > 0 else { continue }
    let input = mutate(source, rng)
    let outcome = try
      drive(
        Decoder(),
        input,
        next_in=() => 1 + rng.below(64),
        next_out=() => 1 + rng.below(4096),
        check=check_bounds,
      )
    catch {
      @codec.CodecError(kind, _) => Repr(kind).to_string()
      err => fail("unexpected error: \{Repr(err)}")
    } noraise {
      _ => "decoded"
    }
    tally[outcome] = tally.get(outcome).unwrap_or(0) + 1
  }
  debug_inspect(
    tally,
    content=(
      #|{
      #|  "Truncated": 1009,
      #|  "TrailingData": 85,
      #|  "Corrupt": 733,
      #|  "decoded": 173,
      #|}
    ),
  )
}
