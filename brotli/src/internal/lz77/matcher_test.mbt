// Generated from parts/lz77/matcher_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
fn bytes_of(s : String) -> FixedArray[Byte] {
  FixedArray::makei(s.length(), i => s[i].to_byte())
}

///|
test "finds the longest match, nearest on a tie" {
  let data = bytes_of("abcdXabcdeYabcdZabcde")
  let m = @lz77.Matcher()
  let found = []
  for pos in 0..<data.length() {
    let len = m.find(data, pos, data.length(), 1 << 20, 1 << 20)
    if len > 0 {
      found.push((pos, len, m.distance()))
    }
  }
  // At 11 "abcd" matches 6 and 11 back; at 16 "abcde" matches 11 back.
  debug_inspect(
    found,
    content="[(5, 4, 5), (11, 4, 6), (16, 5, 11), (17, 4, 11)]",
  )
}

///|
test "matches respect the distance and length limits and the end" {
  let data = bytes_of("0123456789" + "0123456789")
  let m = @lz77.Matcher()
  for pos in 0..<10 {
    assert_eq(m.find(data, pos, 20, 10, 100), 0)
  }
  inspect(m.find(data, 10, 20, 10, 6), content="6")
  inspect(m.distance(), content="10")
  m.reset()
  for pos in 0..<10 {
    assert_eq(m.find(data, pos, 20, 9, 100), 0)
  }
  // Ten back is beyond the distance limit.
  inspect(m.find(data, 10, 20, 9, 100), content="0")
  m.reset()
  for pos in 0..<10 {
    m.find(data, pos, 13, 100, 100) |> ignore
  }
  // Only three bytes are left before the end: no match.
  inspect(m.find(data, 10, 13, 100, 100), content="0")
  inspect(m.find(data, 16, 20, 100, 100), content="4")
}

///|
test "overlapping matches find runs" {
  let data = FixedArray::make(100, b'a')
  let m = @lz77.Matcher()
  inspect(m.find(data, 0, 100, 1000, 1000), content="0")
  inspect(m.find(data, 1, 100, 1000, 1000), content="99")
  inspect(m.distance(), content="1")
  inspect(@lz77.match_length(data, 0, 50, 50), content="50")
}

///|
test "sliding keeps the positions that stay in the buffer" {
  let data = bytes_of("abcdefgh" + "abcdefgh" + "abcdefgh")
  let m = @lz77.Matcher(hash_bits=8)
  inspect(m.capacity(), content="1024")
  for pos in 0..<16 {
    m.find(data, pos, 16, 100, 100) |> ignore
  }
  // Move the buffer down by 8: "abcdefgh" + "abcdefgh".
  let slid = FixedArray::make(16, b'\x00')
  FixedArray::unsafe_blit(slid, 0, data, 8, 16)
  m.slide(8)
  inspect(m.find(slid, 8, 16, 100, 100), content="8")
  inspect(m.distance(), content="8")
  // Sliding past every position empties the table.
  m.slide(100)
  inspect(m.find(slid, 0, 16, 100, 100), content="0")
}

///|
test "buckets keep the newest positions" {
  // Five earlier copies of "wxyz": only the newest four are candidates,
  // and the bucket's oldest is beyond reach.
  let data = bytes_of("wxyz1wxyz2wxyz3wxyz4wxyz5wxyz6")
  let m = @lz77.Matcher()
  for pos in 0..<25 {
    m.find(data, pos, 30, 100, 100) |> ignore
  }
  inspect(m.find(data, 25, 30, 100, 100), content="4")
  inspect(m.distance(), content="5")
}
