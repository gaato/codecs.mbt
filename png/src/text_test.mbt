///|
fn error_of(f : () -> Unit raise @codec.CodecError) -> String {
  try f() catch {
    @codec.CodecError(kind, _) => return "\{Repr(kind)}"
  } noraise {
    _ => "ok"
  }
}

///|
test "parse_text reads tEXt, zTXt and iTXt blocks" {
  debug_inspect(
    @png.parse_text("tEXt", b"Author\x00caf\xe9"[:]),
    content=(
      #|{
      #|  keyword: "Author",
      #|  language: "",
      #|  translated_keyword: "",
      #|  text: "café",
      #|}
    ),
  )
  debug_inspect(
    @png.parse_text("zTXt", b"Comment\x00two words"[:]),
    content=(
      #|{
      #|  keyword: "Comment",
      #|  language: "",
      #|  translated_keyword: "",
      #|  text: "two words",
      #|}
    ),
  )
  // iTXt: keyword, NUL, flag and method (0 in the block), language tag,
  // NUL, translated keyword (UTF-8), NUL, text (UTF-8).
  let block = b"Title\x00\x00\x00ja-JP\x00\xe9\xa1\x8c\x00\xe3\x81\x82"
  debug_inspect(
    @png.parse_text("iTXt", block[:]),
    content=(
      #|{
      #|  keyword: "Title",
      #|  language: "ja-JP",
      #|  translated_keyword: "題",
      #|  text: "あ",
      #|}
    ),
  )
  debug_inspect(
    @png.parse_text("iTXt", b"k\x00\x00\x00\x00\x00"[:]),
    content=(
      #|{ keyword: "k", language: "", translated_keyword: "", text: "" }
    ),
  )
}

///|
test "parse_text refuses what the specification does not allow" {
  let cases : Array[(String, Bytes)] = [
    ("tEXt", b"\x00text"),
    ("tEXt", Bytes::make(80, b'k') + b"\x00text"),
    ("tEXt", b" lead\x00text"),
    ("tEXt", b"trail \x00text"),
    ("tEXt", b"two  spaces\x00text"),
    ("tEXt", b"tab\x09\x00text"),
    ("tEXt", b"nbsp\xa0\x00text"),
    ("tEXt", b"no nul"),
    ("tEXt", b"key\x00a\x00b"),
    ("iTXt", b"key\x00\x00"),
    ("iTXt", b"key\x00\x00\x00en_US\x00\x00text"),
    ("iTXt", b"key\x00\x00\x00en\x00\xff\x00text"),
    ("iTXt", b"key\x00\x00\x00en\x00\x00\xc3"),
    ("iTXt", b"key\x00\x00\x00en"),
    ("iTXt", b"k\x00\x00\x00en--US\x00\x00text"),
    ("iTXt", b"k\x00\x00\x00-en\x00\x00text"),
    ("iTXt", b"k\x00\x00\x00en-\x00\x00text"),
    ("iTXt", b"k\x00\x00\x00x-abcdefghi\x00\x00text"),
    ("iTXt", b"k\x00\x00\x001en\x00\x00text"),
    ("iTXt", b"k\x00\x00\x00en\x00\x00a\x00b"),
    ("iTXt", b"k\x00\x00\x00en\x00translated, no NUL"),
  ]
  for c in cases {
    let (kind, block) = c
    let got = error_of(() => @png.parse_text(kind, block[:]) |> ignore)
    assert_eq(got, "Corrupt", msg="\{kind} \{block}")
  }
  // Tags of subtags, and a keyword of 79 bytes, are fine.
  for
    tag in [
      b"en", b"en-US", b"zh-Hant-TW", b"x-private", b"de-1996", b"i-klingon",
    ] {
    let block = b"k\x00\x00\x00" + tag + b"\x00\x00text"
    assert_eq(@png.parse_text("iTXt", block[:]).text, "text")
  }
  let long = Bytes::make(79, b'k') + b"\x00x"
  assert_eq(@png.parse_text("tEXt", long[:]).keyword.length(), 79)
  inspect(
    error_of(() => @png.parse_text("iCCP", b"p\x00x"[:]) |> ignore),
    content="Unsupported",
  )
}

///|
test "parse_time reads tIME and refuses fields out of range" {
  debug_inspect(
    @png.parse_time(b"\x07\xea\x0b\x0f\x17\x3b\x3c"[:]),
    content=(
      #|{ year: 2026, month: 11, day: 15, hour: 23, minute: 59, second: 60 }
    ),
  )
  let bad : Array[Bytes] = [
    b"\x07\xea\x00\x0f\x00\x00\x00", b"\x07\xea\x0d\x0f\x00\x00\x00", b"\x07\xea\x01\x00\x00\x00\x00",
    b"\x07\xea\x01\x20\x00\x00\x00", b"\x07\xea\x01\x01\x18\x00\x00", b"\x07\xea\x01\x01\x00\x3c\x00",
    b"\x07\xea\x01\x01\x00\x00\x3d", b"\x07\xea\x01\x01\x00\x00", b"\x07\xea\x01\x01\x00\x00\x00\x00",
  ]
  for block in bad {
    assert_eq(error_of(() => @png.parse_time(block[:]) |> ignore), "Corrupt")
  }
}
