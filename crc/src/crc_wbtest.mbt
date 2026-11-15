///|
/// Bytes from a seeded LCG, the same as the Python that computed the zlib
/// values below draws.
fn lcg_bytes(n : Int32, seed : UInt64) -> Bytes {
  let mut state = seed
  Bytes::makei(n, _ => {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    (state >> 56).to_byte()
  })
}

///|
/// The CRC of `data` bit by bit, as the reveng model defines it, with no
/// table and no reflection of the register: each input bit (the least
/// significant first when `reflect_in`) enters at the register's top.
fn bitwise(c : Crc, data : BytesView) -> UInt64 {
  let top = 1UL << (c.width - 1)
  let mut r = c.init
  for b in data {
    for k in 0..<8 {
      let bit = if c.reflect_in {
        (b.to_uint64() >> k) & 1
      } else {
        (b.to_uint64() >> (7 - k)) & 1
      }
      let feedback = (if (r & top) != 0 { 1UL } else { 0UL }) ^ bit
      r = (r << 1) & c.mask
      if feedback != 0 {
        r = r ^ c.poly
      }
    }
  }
  (if c.reflect_out { reflect(r, c.width) } else { r }) ^ c.xor_out
}

///|
/// `c` with its table, even when it has a faster way.
fn table_only(c : Crc) -> Crc {
  { ..c, engine: Table, }
}

///|
test "every CRC of the catalogue gives its check value and its residue" {
  assert_eq(expected.length(), catalogue.length())
  for e in expected {
    let (name, check, residue) = e
    guard Crc::named(name) is Some(c) else { fail("no \{name}") }
    assert_eq(c.checksum(b"123456789"), check, msg=name)
    assert_eq(table_only(c).checksum(b"123456789"), check, msg=name)
    assert_eq(bitwise(c, b"123456789"), check, msg=name)
    // The residue: the register after the message and its CRC, sent in
    // the order the CRC is output (least significant byte first when
    // reflected), before xor_out. Only whole bytes can be sent.
    guard c.width % 8 == 0 else { continue }
    let n = c.width / 8
    let crc_bytes = Bytes::makei(n, i => {
      let shift = if c.reflect_out { 8 * i } else { 8 * (n - 1 - i) }
      (check >> shift).to_byte()
    })
    let after = c.update(check, crc_bytes)
    assert_eq(after ^ c.xor_out, residue, msg="\{name} residue")
  }
}

///|
test "names and aliases are unique, and found in any case" {
  let seen : Map[String, String] = Map([])
  for e in catalogue {
    for n in [e.name, ..e.aliases] {
      assert_false(seen.contains(n), msg=n)
      seen[n] = e.name
    }
  }
  guard Crc::named("crc-32") is Some(a) else { fail("crc-32") }
  guard Crc::named("CRC-32/ISO-HDLC") is Some(b) else { fail("iso-hdlc") }
  assert_eq(a.checksum(b"abc"), b.checksum(b"abc"))
  assert_true(Crc::named("CRC-82/DARC") is None)
  assert_true(Crc::named("no such crc") is None)
}

///|
test "tables match the bit-by-bit definition on data of any length" {
  for e in catalogue {
    guard Crc::named(e.name) is Some(c) else { fail(e.name) }
    for n in [0, 1, 2, 3, 15, 64, 100] {
      let data = lcg_bytes(n, n.to_uint64() + 3)
      assert_eq(c.checksum(data), bitwise(c, data), msg="\{e.name} \{n}")
    }
  }
}

///|
test "the fast CRCs are their tables' CRCs at every alignment and length" {
  let data = lcg_bytes(1100, 42)
  for c in [crc32, crc32c, crc64_xz] {
    let slow = table_only(c)
    for start in 0..<8 {
      for len in 0..<=1024 {
        let piece = data[start:start + len]
        assert_eq(c.checksum(piece), slow.checksum(piece))
      }
    }
  }
  assert_eq(crc32_update(0, b"123456789"), 0xCBF43926)
  assert_eq(crc32c_update(0, b"123456789"), 0xE3069283)
  assert_eq(crc64_xz_update(0, b"123456789"), 0x995DC9BBDF1939FA)
  // Continued from a CRC so far.
  let head = crc64_xz_update(0, data[:333])
  assert_eq(crc64_xz_update(head, data[333:]), crc64_xz_update(0, data[:]))
}

///|
test "CRC-32 agrees with Python's zlib.crc32" {
  let zlib = [
    (0, 0U),
    (1, 1309403428U),
    (7, 3642133028U),
    (8, 1676775386U),
    (9, 4288411535U),
    (1000, 2785915125U),
    (65536, 3049237185U),
  ]
  for z in zlib {
    let (n, value) = z
    let data = lcg_bytes(n, n.to_uint64() + 1)
    assert_eq(crc32_update(0, data), value)
    assert_eq(crc32.checksum(data), value.to_uint64())
  }
}

///|
test "combine gives the CRC of the two pieces one after the other" {
  let mut state = 7UL
  let next = (bound : Int32) => {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    ((state >> 33) % bound.to_uint64()).to_int()
  }
  let data = lcg_bytes(3000, 9)
  for e in catalogue {
    guard Crc::named(e.name) is Some(c) else { fail(e.name) }
    for _ in 0..<12 {
      let cut = next(data.length() + 1)
      let end = cut + next(data.length() - cut + 1)
      let a = data[:cut]
      let b = data[cut:end]
      let whole = c.checksum(data[:end])
      assert_eq(
        c.combine(c.checksum(a), c.checksum(b), b.length().to_int64()),
        whole,
        msg=e.name,
      )
    }
    // An empty second piece leaves the first's CRC.
    let x = c.checksum(b"x")
    assert_eq(c.combine(x, c.checksum(b""), 0L), x)
  }
}

///|
test "combine's powers of x add their exponents, past 2^31 bytes" {
  for
    c in [
      crc32,
      crc32c,
      crc64_xz,
      Crc::named("CRC-16/ARC").unwrap(),
      Crc::named("CRC-5/USB").unwrap(),
    ] {
    for
      pair in [
        (1L << 31, 12345L),
        (1L << 40, 1L << 33),
        (3L, 0x7FFFFFFFFFFFFFF0L),
      ] {
      let (m, n) = pair
      assert_eq(c.x8_power(m + n), c.multiply(c.x8_power(m), c.x8_power(n)))
    }
    // The CRC of 2^21 zero bytes, from doubling with combine, is the CRC
    // of them computed directly.
    let zeros = Bytes::make(1 << 21, b'\x00')
    let mut crc = c.checksum(zeros[:1 << 10])
    let mut len = 1L << 10
    while len < 1L << 21 {
      crc = c.combine(crc, crc, len)
      len = len * 2
    }
    assert_eq(crc, c.checksum(zeros))
  }
}

///|
test "a digest gives the CRC of what it was written, in pieces" {
  let d = crc32c.digest()
  assert_eq(d.value(), crc32c.checksum(b""))
  d.write(b"1234")
  d.write(b"56789")
  assert_eq(d.value(), 0xE3069283)
  d.reset()
  d.write(b"abc")
  assert_eq(d.value(), crc32c.checksum(b"abc"))
}

///|
test "panic Crc::new refuses a width of 0" {
  Crc::new(width=0, poly=1) |> ignore
}

///|
test "panic Crc::new refuses a width over 64" {
  Crc::new(width=65, poly=1) |> ignore
}

///|
test "panic Crc::new refuses a polynomial wider than the width" {
  Crc::new(width=8, poly=0x107) |> ignore
}

///|
test "a Crc holds a table of 256 entries, and the fast ones' tables are fixed" {
  for e in catalogue {
    guard Crc::named(e.name) is Some(c) else { fail(e.name) }
    assert_eq(c.table.length(), 256)
  }
  assert_eq(crc64_tables.length(), 8 * 256)
  assert_eq(crc64_table.length(), 256)
}

///|
test "try_new says why parameters make no CRC" {
  debug_inspect(
    Crc::try_new(width=0, poly=1).map(_ => ()),
    content="Err(\"the width must be 1 to 64, not 0\")",
  )
  debug_inspect(
    Crc::try_new(width=8, poly=0x07, xor_out=0x100).map(_ => ()),
    content="Err(\"poly, init and xor_out must fit in 8 bits\")",
  )
  guard Crc::try_new(width=64, poly=0x42F0E1EBA9EA3693, reflect_in=true)
    is Ok(c) else {
    fail("a valid CRC")
  }
  assert_eq(c.width, 64)
}
