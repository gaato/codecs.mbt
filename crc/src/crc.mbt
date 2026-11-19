///|
/// A cyclic redundancy check of 1 to 64 bits, by Ross Williams's
/// parameters as the reveng catalogue gives them: the polynomial `poly`
/// without its top term, the register's start `init`, whether input bytes
/// are taken least significant bit first (`reflect_in`), whether the
/// register is reflected before it is output (`reflect_out`), and `xor_out`,
/// what the output is XORed with. A CRC is the same value however the data
/// is split, and two CRCs combine into the CRC of the data one after the
/// other (`combine`).
pub struct Crc {
  width : Int32
  poly : UInt64
  init : UInt64
  reflect_in : Bool
  reflect_out : Bool
  xor_out : UInt64
  priv mask : UInt64
  // The register after a byte from each register's low (reflected) or top
  // byte, 256 entries.
  priv table : RegisterTable
  priv engine : Engine
}

///|
#cfg(any(target="wasm", target="js"))
priv enum RegisterTable {
  Narrow(FixedArray[UInt32])
  Wide(FixedArray[UInt64])
}

///|
// CRC-32/BZIP2 was faster with the wide register on native and Wasm GC.
#cfg(not(any(target="wasm", target="js")))
type RegisterTable = FixedArray[UInt64]

///|
/// How a `Crc` runs over data: from its table, or eight bytes at a time
/// for the three of `crc32`, `crc32c` and `crc64_xz`.
priv enum Engine {
  Table
  Crc32
  Crc32c
  Crc64Xz
}

///|
/// The CRC with these parameters (see `Crc`). `reflect_out` is
/// `reflect_in` unless given. Aborts unless `width` is 1 to 64 and `poly`,
/// `init` and `xor_out` fit in it, for parameters the program writes;
/// `try_new` checks parameters that come from data.
pub fn Crc::new(
  width~ : Int32,
  poly~ : UInt64,
  init~ : UInt64 = 0,
  reflect_in~ : Bool = false,
  reflect_out? : Bool,
  xor_out~ : UInt64 = 0,
) -> Crc {
  match
    Crc::try_new(width~, poly~, init~, reflect_in~, reflect_out?, xor_out~) {
    Ok(crc) => crc
    Err(reason) => abort("Crc::new: \{reason}")
  }
}

///|
/// The CRC with these parameters, as `new` makes it, or why there is none:
/// a width outside 1 to 64, or a `poly`, `init` or `xor_out` that does not
/// fit in the width.
pub fn Crc::try_new(
  width~ : Int32,
  poly~ : UInt64,
  init~ : UInt64 = 0,
  reflect_in~ : Bool = false,
  reflect_out? : Bool,
  xor_out~ : UInt64 = 0,
) -> Result[Crc, String] {
  guard width >= 1 && width <= 64 else {
    return Err("the width must be 1 to 64, not \{width}")
  }
  let mask = if width == 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << width) - 1 }
  guard (poly & mask.lnot()) == 0 &&
    (init & mask.lnot()) == 0 &&
    (xor_out & mask.lnot()) == 0 else {
    return Err("poly, init and xor_out must fit in \{width} bits")
  }
  let reflect_out = reflect_out.unwrap_or(reflect_in)
  let table = if reflect_in {
    let p = reflect(poly, width)
    FixedArray::makei(256, n => {
      let mut c = n.to_uint64()
      for _ in 0..<8 {
        c = if (c & 1) != 0 { (c >> 1) ^ p } else { c >> 1 }
      }
      c
    })
  } else {
    let p = poly << (64 - width)
    FixedArray::makei(256, n => {
      let mut c = n.to_uint64() << 56
      for _ in 0..<8 {
        c = if c >> 63 != 0 { (c << 1) ^ p } else { c << 1 }
      }
      c
    })
  }
  let engine = if reflect_in &&
    reflect_out &&
    width == 32 &&
    poly == 0x04C11DB7 &&
    init == 0xFFFFFFFF &&
    xor_out == 0xFFFFFFFF {
    Crc32
  } else if reflect_in &&
    reflect_out &&
    width == 32 &&
    poly == 0x1EDC6F41 &&
    init == 0xFFFFFFFF &&
    xor_out == 0xFFFFFFFF {
    Crc32c
  } else if reflect_in &&
    reflect_out &&
    width == 64 &&
    poly == 0x42F0E1EBA9EA3693 &&
    init == mask &&
    xor_out == mask {
    Crc64Xz
  } else {
    Table
  }
  Ok({
    width,
    poly,
    init,
    reflect_in,
    reflect_out,
    xor_out,
    mask,
    table: register_table(table, width, reflect_in),
    engine,
  })
}

///|
#cfg(any(target="wasm", target="js"))
fn register_table(
  table : FixedArray[UInt64],
  width : Int32,
  reflect_in : Bool,
) -> RegisterTable {
  if width <= 32 {
    let shift = if reflect_in { 0 } else { 32 }
    Narrow(FixedArray::makei(256, i => (table[i] >> shift).to_uint()))
  } else {
    Wide(table)
  }
}

///|
#cfg(not(any(target="wasm", target="js")))
#inline
fn register_table(
  table : FixedArray[UInt64],
  _width : Int32,
  _reflect_in : Bool,
) -> RegisterTable {
  table
}

///|
/// The CRC of `data`.
pub fn Crc::checksum(self : Crc, data : BytesView) -> UInt64 {
  self.update(self.empty(), data)
}

///|
/// The CRC of the data so far, whose CRC is `crc`, extended by `data`:
/// `update(checksum(a), b)` is `checksum(a + b)`, and the CRC of no data is
/// `checksum(b"")`.
#cfg(any(target="wasm", target="js"))
pub fn Crc::update(self : Crc, crc : UInt64, data : BytesView) -> UInt64 {
  match self.engine {
    Crc32 => @crc32.update_bytes(crc.to_uint(), data).to_uint64()
    Crc32c => @crc32c.update_bytes(crc.to_uint(), data).to_uint64()
    Crc64Xz => crc64_xz_update(crc, data)
    Table => self.update_table(crc & self.mask, data)
  }
}

///|
/// The CRC of the data so far, whose CRC is `crc`, extended by `data`:
/// `update(checksum(a), b)` is `checksum(a + b)`, and the CRC of no data is
/// `checksum(b"")`.
#cfg(not(any(target="wasm", target="js")))
pub fn Crc::update(self : Crc, crc : UInt64, data : BytesView) -> UInt64 {
  match self.engine {
    Crc32 => @crc32.update_bytes(crc.to_uint(), data).to_uint64()
    Crc32c => @crc32c.update_bytes(crc.to_uint(), data).to_uint64()
    Crc64Xz => crc64_xz_update(crc, data)
    Table => self.output(self.run(self.register(crc & self.mask), data))
  }
}

///|
/// The CRC of `a` followed by `b`, from `crc_a`, the CRC of `a`, `crc_b`,
/// that of `b`, and `len_b`, the length of `b` in bytes (0 for a negative
/// one), in time logarithmic in `len_b`, as zlib's `crc32_combine` does.
pub fn Crc::combine(
  self : Crc,
  crc_a : UInt64,
  crc_b : UInt64,
  len_b : Int64,
) -> UInt64 {
  // In the polynomial's own order, the register is linear in its start:
  // CRC(ab) = CRC(b) + (CRC(a) + init) * x^(8 * len_b) mod poly, before the
  // output's reflection and XOR.
  let a = self.normal(crc_a & self.mask)
  let b = self.normal(crc_b & self.mask)
  let shifted = self.multiply(a ^ self.init, self.x8_power(len_b.max(0L)))
  self.from_normal(b ^ shifted)
}

///|
/// A running CRC: `write` data in pieces, `value` is the CRC of all of it.
pub struct Digest {
  priv crc : Crc
  priv mut value : UInt64
}

///|
/// A digest of no data yet.
pub fn Crc::digest(self : Crc) -> Digest {
  { crc: self, value: self.empty(), }
}

///|
/// Adds `data` to what the digest has seen.
pub fn Digest::write(self : Digest, data : BytesView) -> Unit {
  self.value = self.crc.update(self.value, data)
}

///|
/// The CRC of the data written so far.
pub fn Digest::value(self : Digest) -> UInt64 {
  self.value
}

///|
/// Forgets the data written, as if new.
pub fn Digest::reset(self : Digest) -> Unit {
  self.value = self.crc.empty()
}

///|
/// The CRC of no data.
fn Crc::empty(self : Crc) -> UInt64 {
  self.from_normal(self.init)
}

///|
/// The register the table runs, from an output value.
#cfg(not(target="native"))
fn Crc::register(self : Crc, crc : UInt64) -> UInt64 {
  if self.reflect_in {
    let x = crc ^ self.xor_out
    // The two reflections of a width-bit value cancel.
    if self.reflect_out {
      x
    } else {
      reflect(x, self.width)
    }
  } else {
    self.normal(crc) << (64 - self.width)
  }
}

///|
// Keep the reflected whole-input loop's native code generation.
#cfg(target="native")
fn Crc::register(self : Crc, crc : UInt64) -> UInt64 {
  let normal = self.normal(crc)
  if self.reflect_in {
    reflect(normal, self.width)
  } else {
    normal << (64 - self.width)
  }
}

///|
/// The output value of a register the table ran.
#cfg(not(target="native"))
fn Crc::output(self : Crc, register : UInt64) -> UInt64 {
  if self.reflect_in {
    let r = if self.reflect_out {
      register
    } else {
      reflect(register, self.width)
    }
    r ^ self.xor_out
  } else {
    self.from_normal(register >> (64 - self.width))
  }
}

///|
#cfg(target="native")
fn Crc::output(self : Crc, register : UInt64) -> UInt64 {
  let normal = if self.reflect_in {
    reflect(register, self.width)
  } else {
    register >> (64 - self.width)
  }
  self.from_normal(normal)
}

///|
/// The register in the polynomial's order (its top bit the highest term),
/// from an output value: the XOR undone, and the reflection.
fn Crc::normal(self : Crc, crc : UInt64) -> UInt64 {
  let x = crc ^ self.xor_out
  if self.reflect_out {
    reflect(x, self.width)
  } else {
    x
  }
}

///|
/// The output value of a register in the polynomial's order.
fn Crc::from_normal(self : Crc, normal : UInt64) -> UInt64 {
  (if self.reflect_out { reflect(normal, self.width) } else { normal }) ^
  self.xor_out
}

///|
/// Updates the table engine's CRC with `data`.
#cfg(any(target="wasm", target="js"))
fn Crc::update_table(self : Crc, crc : UInt64, data : BytesView) -> UInt64 {
  match self.table {
    Narrow(table) => self.update_narrow(table, crc, data)
    Wide(table) => self.output(self.run_wide(table, self.register(crc), data))
  }
}

///|
#cfg(any(target="wasm", target="js"))
fn Crc::update_narrow(
  self : Crc,
  table : FixedArray[UInt32],
  crc : UInt64,
  data : BytesView,
) -> UInt64 {
  if self.reflect_in {
    let mut r = self.register(crc).to_uint()
    for b in data {
      // Masking to a byte gives an index within the 256 entries.
      r = table.unsafe_get(((r ^ b.to_uint()) & 0xFF).reinterpret_as_int()) ^
        (r >> 8)
    }
    self.output(r.to_uint64())
  } else {
    let shift = 32 - self.width
    let mut r = self.normal(crc).to_uint() << shift
    for b in data {
      // The high byte XOR the input byte is within the 256 entries.
      r = table.unsafe_get(((r >> 24) ^ b.to_uint()).reinterpret_as_int()) ^
        (r << 8)
    }
    self.from_normal((r >> shift).to_uint64())
  }
}

///|
#cfg(any(target="wasm", target="js"))
fn Crc::run_wide(
  self : Crc,
  table : FixedArray[UInt64],
  register : UInt64,
  data : BytesView,
) -> UInt64 {
  let mut r = register
  if self.reflect_in {
    for b in data {
      // An index of a byte: within the 256 entries.
      r = table.unsafe_get(((r ^ b.to_uint64()) & 0xFF).to_int()) ^ (r >> 8)
    }
  } else {
    for b in data {
      // The high byte XOR the input byte is within the 256 entries.
      r = table.unsafe_get(((r >> 56) ^ b.to_uint64()).to_int()) ^ (r << 8)
    }
  }
  r
}

///|
#cfg(not(any(target="wasm", target="js")))
fn Crc::run(self : Crc, register : UInt64, data : BytesView) -> UInt64 {
  let table = self.table
  let mut r = register
  if self.reflect_in {
    for b in data {
      // An index of a byte: within the 256 entries.
      r = table.unsafe_get(((r ^ b.to_uint64()) & 0xFF).to_int()) ^ (r >> 8)
    }
  } else {
    for b in data {
      // The high byte XOR the input byte is within the 256 entries.
      r = table.unsafe_get(((r >> 56) ^ b.to_uint64()).to_int()) ^ (r << 8)
    }
  }
  r
}

///|
/// `v` times x, modulo the polynomial, in its order.
fn Crc::times_x(self : Crc, v : UInt64) -> UInt64 {
  let top = (v >> (self.width - 1)) & 1
  let shifted = (v << 1) & self.mask
  if top != 0 {
    shifted ^ self.poly
  } else {
    shifted
  }
}

///|
/// `a` times `b`, modulo the polynomial, in its order.
fn Crc::multiply(self : Crc, a : UInt64, b : UInt64) -> UInt64 {
  let mut product = 0UL
  for i = self.width - 1; i >= 0; i = i - 1 {
    product = self.times_x(product)
    if ((b >> i) & 1) != 0 {
      product = product ^ a
    }
  }
  product
}

///|
/// x^(8 * n) modulo the polynomial, by squaring: what a register becomes
/// over `n` zero bytes is the register times it.
fn Crc::x8_power(self : Crc, n : Int64) -> UInt64 {
  let mut base = 1UL
  for _ in 0..<8 {
    base = self.times_x(base)
  }
  let mut result = 1UL
  let mut k = n
  while k > 0L {
    if (k & 1L) != 0L {
      result = self.multiply(result, base)
    }
    base = self.multiply(base, base)
    k = k >> 1
  }
  result
}

///|
/// The low `width` bits of `v` in reverse order.
fn reflect(v : UInt64, width : Int32) -> UInt64 {
  let mut out = 0UL
  for i in 0..<width {
    out = (out << 1) | ((v >> i) & 1)
  }
  out
}
