///|
/// A text chunk (PNG section 11.3.3), as `parse_text` reads its block:
/// tEXt and zTXt have a keyword and text in Latin-1; iTXt also has a
/// language tag and a translated keyword, and its translated keyword and
/// text are UTF-8. For tEXt and zTXt, `language` and `translated_keyword`
/// are empty.
#derive(Eq, @debug.Debug)
pub(all) struct Text {
  keyword : String
  language : String
  translated_keyword : String
  text : String
}

///|
/// A tIME chunk (PNG section 11.3.6.1): the image's last modification, in
/// UTC.
#derive(Eq, @debug.Debug)
pub(all) struct Time {
  year : Int32
  month : Int32
  day : Int32
  hour : Int32
  minute : Int32
  second : Int32
}

///|
/// Reads the block of a text chunk that `Decoder(report=...)` handed out,
/// with the type `metadata_type()` named: tEXt, zTXt (its text already
/// inflated) or iTXt (its compression fields already set to 0). Raises
/// `Corrupt` for what the specification does not allow: a keyword that is
/// not 1 to 79 printable Latin-1 characters with single spaces between
/// words, a NUL in the text, a language tag that is not BCP 47's subtags
/// (1 to 8 letters or digits between single hyphens, the first of
/// letters), or a translated keyword or text that is not UTF-8; and
/// `Unsupported` for another chunk type.
pub fn parse_text(
  chunk_type : String,
  block : BytesView,
) -> Text raise @codec.CodecError {
  guard chunk_type is ("tEXt" | "zTXt" | "iTXt") else {
    raise @codec.CodecError(
      Unsupported,
      "\{chunk_type} is not a text chunk (tEXt, zTXt or iTXt)",
    )
  }
  let keyword_end = find_nul(block, 0)
  guard keyword_end >= 0 else {
    raise corrupt_text("a keyword without its NUL")
  }
  let keyword = keyword_of(block[0:keyword_end])
  if chunk_type != "iTXt" {
    let body = block[keyword_end + 1:]
    guard find_nul(body, 0) < 0 else { raise corrupt_text("a NUL in the text") }
    return {
      keyword,
      language: "",
      translated_keyword: "",
      text: latin1(body),
    }
  }
  // The compression flag and method, then the language tag and the
  // translated keyword, each ended by a NUL.
  let at = keyword_end + 3
  guard at <= block.length() else { raise corrupt_text("an iTXt cut short") }
  let language_end = find_nul(block, at)
  guard language_end >= 0 else {
    raise corrupt_text("a language tag without its NUL")
  }
  let language = block[at:language_end]
  guard well_formed_language(language) else {
    raise corrupt_text("a language tag that is not BCP 47's subtags")
  }
  let translated_end = find_nul(block, language_end + 1)
  guard translated_end >= 0 else {
    raise corrupt_text("a translated keyword without its NUL")
  }
  let text = block[translated_end + 1:]
  guard find_nul(text, 0) < 0 else { raise corrupt_text("a NUL in the text") }
  {
    keyword,
    language: latin1(language),
    translated_keyword: utf8(block[language_end + 1:translated_end]),
    text: utf8(text),
  }
}

///|
/// Reads a tIME chunk's 7 bytes: the year (2 bytes, big-endian), month (1
/// to 12), day (1 to 31), hour (0 to 23), minute (0 to 59) and second (0 to
/// 60, for a leap second). Raises `Corrupt` for another length or a field
/// out of its range.
pub fn parse_time(block : BytesView) -> Time raise @codec.CodecError {
  guard block.length() == 7 else {
    raise corrupt_text("a tIME of \{block.length()} bytes, not 7")
  }
  let time = {
    year: (block[0].to_int() << 8) | block[1].to_int(),
    month: block[2].to_int(),
    day: block[3].to_int(),
    hour: block[4].to_int(),
    minute: block[5].to_int(),
    second: block[6].to_int(),
  }
  guard time.month >= 1 &&
    time.month <= 12 &&
    time.day >= 1 &&
    time.day <= 31 &&
    time.hour <= 23 &&
    time.minute <= 59 &&
    time.second <= 60 else {
    raise corrupt_text("a tIME field out of its range")
  }
  time
}

///|
fn corrupt_text(message : String) -> @codec.CodecError {
  @codec.CodecError(Corrupt, message)
}

///|
/// The position of the first NUL of `data` from `from`, or -1.
fn find_nul(data : BytesView, from : Int32) -> Int32 {
  for i in from..<data.length() {
    if data[i] == b'\x00' {
      return i
    }
  }
  -1
}

///|
/// A keyword, checked as the specification has it: 1 to 79 bytes of
/// printable Latin-1 (32 to 126 and 161 to 255), no space first or last and
/// no two in a row.
fn keyword_of(bytes : BytesView) -> String raise @codec.CodecError {
  let n = bytes.length()
  guard n >= 1 && n <= 79 else {
    raise corrupt_text("a keyword of \{n} bytes, not 1 to 79")
  }
  for i, b in bytes {
    guard (b >= b' ' && b <= b'~') || b >= b'\xa1' else {
      raise corrupt_text(
        "a keyword with a character that is not printable Latin-1",
      )
    }
    if b == b' ' && (i == 0 || i == n - 1 || bytes[i - 1] == b' ') {
      raise corrupt_text("a keyword with a space first, last or twice")
    }
  }
  latin1(bytes)
}

///|
/// Whether `tag` is empty (the language is unknown) or has the shape of a
/// BCP 47 tag: subtags of 1 to 8 letters or digits between single hyphens,
/// the first of letters. This is the tag's syntax at the level of its
/// subtags, not BCP 47's whole grammar (which subtag may follow which).
fn well_formed_language(tag : BytesView) -> Bool {
  let mut length = 0
  let mut first = true
  for b in tag {
    if b == b'-' {
      guard length > 0 else { return false }
      length = 0
      first = false
    } else {
      let letter = (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z')
      guard letter || (!first && b >= b'0' && b <= b'9') else { return false }
      length += 1
      guard length <= 8 else { return false }
    }
  }
  tag.length() == 0 || length > 0
}

///|
/// Latin-1 bytes as a string: each byte is the code point of its value.
fn latin1(bytes : BytesView) -> String {
  let out = StringBuilder()
  for b in bytes {
    out.write_char(b.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn utf8(bytes : BytesView) -> String raise @codec.CodecError {
  @utf8.decode(bytes) catch {
    _ => raise corrupt_text("an iTXt field that is not UTF-8")
  }
}

///|
/// Compares two texts field by field.
pub extend Text with Eq::{equal, not_equal}

///|
/// Shows the text as a record of its fields.
pub extend Text with @debug.Debug::{to_repr}

///|
/// Compares two times field by field.
pub extend Time with Eq::{equal, not_equal}

///|
/// Shows the time as a record of its fields.
pub extend Time with @debug.Debug::{to_repr}
