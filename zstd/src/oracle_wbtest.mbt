///|
/// A seeded corruption of a vector and the reference decoder's verdict on
/// it (scripts/gen_oracle_vectors.mbtx): "ok <length> <sha256>" or "err".
priv struct OracleCase {
  source : String
  op : Int32
  at : Int32
  value : Int32
  reference : String
}

///|
/// The source vector with the corruption applied: bit `value` of byte `at`
/// flipped (0), the byte replaced by `value` (1), `value` inserted before it
/// (2), the byte deleted (3), or the stream cut there (4).
fn OracleCase::input(self : OracleCase) -> Bytes {
  let source = vectors[vectors.search_by(v => v.name == self.source).unwrap()]
  let bytes = source.input().to_array()
  match self.op {
    0 => bytes[self.at] = bytes[self.at] ^ (1 << self.value).to_byte()
    1 => bytes[self.at] = self.value.to_byte()
    2 => bytes.insert(self.at, self.value.to_byte())
    3 => bytes.remove(self.at) |> ignore
    _ => bytes.truncate(self.at)
  }
  Bytes::from_array(bytes)
}

///|
test "seeded corruptions: the decoder refuses what the reference refuses" {
  let mut refused = 0
  // The zstd command (ZSTD_decompressStream) decodes a frame whose declared
  // Frame_Content_Size its blocks do not match; zstd's one-shot
  // ZSTD_decompress refuses it (zstd_decompress.c, ZSTD_decompressFrame), and
  // so does this decoder, after every block. Those cases are counted.
  let mut content_size = 0
  for c in oracle {
    let input = c.input()
    let ours = try decompress(input) catch {
      CodecError(_, message) => "err \{message}"
    } noraise {
      out => "ok \{out.length()} \{@checksum.sha256(out)}"
    }
    if ours.has_prefix("err ") &&
      ours.contains("content size") &&
      c.reference.has_prefix("ok ") &&
      inspect_frame(input) is Zstd({ content_size: Some(declared), .. }) &&
      c.reference.split(" ").collect()[1] != declared.to_string() {
      content_size += 1
      continue
    }
    let ours = if ours.has_prefix("err ") { "err" } else { ours }
    if ours != c.reference {
      fail(
        "\{c.source} op \{c.op} at \{c.at} value \{c.value}: ours \{ours}, the reference's \{c.reference}",
      )
    }
    if ours == "err" {
      refused += 1
    }
  }
  assert_true(refused > 0)
  assert_eq(content_size, 1)
}
