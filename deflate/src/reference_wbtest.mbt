// The decoder against zlib: crafted streams and seeded corruptions, each
// with what Node's zlib made of it (scripts/gen_deflate_vectors.mbtx).

///|
fn crafted_decoder(c : Crafted, until : @codec_bytes.Until) -> Decoder {
  match c.dictionary {
    Some(d) => Decoder(dictionary=@fixtures.decode64(d), until~)
    None => Decoder(until~)
  }
}

///|
test "crafted streams: the decoder answers as zlib does" {
  for c in crafted {
    let input = @fixtures.decode64(c.input)
    let first = @fixtures.outcome(crafted_decoder(c, EndOfMember), input)
    let whole = @fixtures.outcome(crafted_decoder(c, EndOfInput), input)
    if @fixtures.disagreement(c.zlib, input.length(), first~, whole~)
      is Some(why) {
      fail("\{c.name}: \{why}")
    }
  }
}

///|
test "seeded corruptions: the decoder answers as zlib does" {
  let tally : Map[String, Int32] = Map([])
  for c in oracle {
    let input = @fixtures.corrupt(c, vector(c.source).input())
    let first = @fixtures.outcome(Decoder(until=EndOfMember), input)
    let whole = @fixtures.outcome(Decoder(), input)
    if @fixtures.disagreement(c.zlib, input.length(), first~, whole~)
      is Some(why) {
      fail("\{c.source} op \{c.op} at \{c.at} value \{c.value}: \{why}")
    }
    let key = match whole.strip_prefix("err ") {
      Some(kind) => kind.to_owned()
      None => "decoded"
    }
    tally[key] = tally.get(key).unwrap_or(0) + 1
  }
  debug_inspect(
    tally,
    content=(
      #|{
      #|  "Corrupt": 321,
      #|  "decoded": 333,
      #|  "Truncated": 315,
      #|  "TrailingData": 31,
      #|}
    ),
  )
}
