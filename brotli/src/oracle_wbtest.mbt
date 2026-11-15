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
  for c in oracle {
    let ours = try decompress(c.input()) catch {
      CodecError(_, _) => "err"
    } noraise {
      out => "ok \{out.length()} \{@checksum.sha256(out)}"
    }
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
}
