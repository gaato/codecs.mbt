///|
test "memory: the buffers, the match finder, the sequences and the codes" {
  let sizes = (level : Int32) => {
    let d = Deflater::new(level~)
    let mf = match (d.hc, d.ht) {
      (Some(hc), _) => hc.memory_usage()
      (_, Some(ht)) => ht.memory_usage()
      _ => 0
    }
    // The counts, codes and statistics of a block, and the code maker.
    let small = d.memory_usage() -
      d.buf.length() -
      d.out.length() -
      mf -
      6 * d.seq_offset.length()
    (
      d.buf.length(),
      d.out.length(),
      mf,
      d.seq_offset.length(),
      small,
      d.memory_usage(),
    )
  }
  debug_inspect(sizes(0), content="(65536, 65541, 0, 0, 0, 131077)")
  debug_inspect(
    sizes(1),
    content="(104447, 65803, 131072, 8193, 11468, 361948)",
  )
  debug_inspect(
    sizes(4),
    content="(104447, 65803, 262144, 16385, 11468, 542172)",
  )
  debug_inspect(
    sizes(6),
    content="(104447, 66147, 262144, 16385, 11468, 542516)",
  )
}

///|
/// The symbols 0 to `k - 1` in an order where every pair of them follows
/// once (a de Bruijn sequence of order 2, cyclic), by the classic recursion.
fn pairs_once(k : Int32) -> Array[Int32] {
  let a = FixedArray::make(3, 0)
  let out = []
  fn db(t : Int32, p : Int32) -> Unit {
    if t > 2 {
      if 2 % p == 0 {
        for i in 1..<=p {
          out.push(a[i])
        }
      }
    } else {
      a[t] = a[t - p]
      db(t + 1, p)
      for j in (a[t - p] + 1)..<k {
        a[t] = j
        db(t + 1, t)
      }
    }
  }
  db(1, 1)
  out
}

///|
/// Tokens of `width` bytes, each with a first byte of its own: with three,
/// 150 of them, every pair of tokens once in 67,500 bytes, so that each
/// token matches the last time it came, a few hundred bytes back, for its
/// own bytes and no further, and a block's sequences run out before its
/// bytes do. With four, 256 tokens drawn at random, for level 1, which takes
/// no match shorter than 4.
fn short_matches(n : Int32, width : Int32) -> Bytes {
  let count = if width == 3 { 150 } else { 256 }
  let tokens = FixedArray::makei(count, i => {
    Array::makei(width, k => ((i * (6 * k + 1) + 37 * k) % 256).to_byte())
  })
  let order = if width == 3 {
    pairs_once(count)
  } else {
    let mut state : UInt32 = 1950
    Array::makei(n / width + 1, _ => {
      state = state * 1664525 + 1013904223
      (state >> 24).reinterpret_as_int()
    })
  }
  let out = Buffer()
  while out.length() < n {
    for t in order {
      for b in tokens[t] {
        out.write_byte(b)
      }
    }
  }
  out.to_bytes()[:n].to_owned()
}

///|
test "a block ends when its sequences fill the store" {
  for level in [1, 2, 6, 9] {
    // Level 1 finds matches of 4 bytes or more, and stops at 8,192.
    let input = short_matches(300000, if level == 1 { 4 } else { 3 })
    let d = Deflater::new(level~)
    let none = FixedArray::make(0, b'\x00')
    let room = FixedArray::make(4096, b'\x00')
    let mut pos = 0
    let mut most = 0
    let mut blocks = 0
    let out = Buffer()
    while !d.is_finished() {
      // With no room, a step stops right after writing a block, and the
      // store still holds that block's sequences.
      let status = d.step_into(input[pos:], none, action=Finish)
      pos += d.last_consumed()
      if status is NeedMoreOutput {
        assert_true(d.nseq <= d.seq_cap)
        most = most.max(d.nseq)
        blocks += 1
      }
      ignore(d.step_into(input[pos:], room, action=Finish))
      pos += d.last_consumed()
      out.write_bytes(Bytes::from_array(room[:d.last_produced()]))
    }
    assert_eq(most, d.seq_cap, msg="level \{level}")
    assert_true(blocks > 1)
    // The stream decodes, through this module's decoder.
    let inflater = @inflate.Inflater::new()
    let back = FixedArray::make(400000, b'\x00')
    let status = inflater.step_into(out.to_bytes(), back, end=true) catch {
      _ => fail("the stream does not decode")
    }
    assert_eq(status, Done)
    assert_eq(Bytes::from_array(back[:inflater.last_produced()]), input)
  }
}
