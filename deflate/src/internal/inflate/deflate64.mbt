// ZIP method 9: APPNOTE 5.6; the extended codes follow zlib 1.3.1's
// contrib/infback9/inftree9.c. RFC 1951's fast loop remains separate.

///|
// A 16-bit length extra field does not fit the ordinary entry's 4-bit extra
// count. A separate kind keeps all existing DEFLATE entries unchanged.
const KIND_LONG_LENGTH : Int32 = 0x500

///|
let distance_base64 : FixedArray[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769, 49153,
]

///|
let distance_table_size64 : Int32 = @huffman.max_entries(
  alphabet=32,
  root_bits=DISTANCE_ROOT_BITS,
).unwrap()

///|
let fixed_literal_table64 : FixedArray[Int32] = fixed_table(
  FixedArray::makei(288, s => {
    if s < 144 {
      8
    } else if s < 256 {
      9
    } else if s < 280 {
      7
    } else {
      8
    }
  }),
  LITERAL_ROOT_BITS,
  LiteralLength64,
)

///|
let fixed_distance_table64 : FixedArray[Int32] = fixed_table(
  FixedArray::make(32, 5),
  DISTANCE_ROOT_BITS,
  Distance64,
)

///|
// Chosen once per step; neither a mode check nor extended entries enter
// DEFLATE's go_fast loop. Shared header/tree units retain their validation.
fn Inflater::run64(
  self : Inflater,
) -> @codec_bytes.Status raise @codec.CodecError {
  for ;; {
    self.checkpoint()
    let status = try {
      if self.state is Codes {
        self.codes64()
      } else {
        self.unit()
      }
    } catch {
      NeedInput => {
        self.rewind()
        return NeedMoreInput
      }
      Fail(kind, message) => raise @codec.CodecError(kind, message)
    }
    if status is Some(status) {
      return status
    }
  }
}

///|
fn Inflater::codes64(self : Inflater) -> @codec_bytes.Status? raise Stop {
  if !self.ensure_space(1) {
    return Some(NeedMoreOutput)
  }
  let entry = self.read_entry(self.lit, LITERAL_ROOT_BITS)
  match entry & KIND_MASK {
    KIND_LITERAL => self.put((entry >> 16).to_byte())
    KIND_BASE | KIND_LONG_LENGTH => {
      let extra = if (entry & KIND_MASK) == KIND_LONG_LENGTH {
        16
      } else {
        (entry >> 4) & 15
      }
      let length = (entry >> 16) + self.read_bits(extra)
      let d = self.read_entry(self.dist, DISTANCE_ROOT_BITS)
      if (d & KIND_MASK) != KIND_BASE {
        raise Fail(Corrupt, invalid_distance)
      }
      // Deflate64 bases 32769 and 49153 set the packed Int32's sign bit.
      // Extract unsigned high bits here; ordinary DEFLATE entries and its
      // fast loop retain their existing representation and shifts.
      let base = (d.reinterpret_as_uint() >> 16).reinterpret_as_int()
      let distance = base + self.read_bits((d >> 4) & 15)
      if distance > self.filled {
        raise Fail(Corrupt, "a distance reaches before the start of the data")
      }
      self.copy_left = length
      self.copy_distance = distance
      self.state = Copy64
    }
    KIND_END_OF_BLOCK => self.end_block()
    _ => raise Fail(Corrupt, invalid_literal)
  }
  None
}

///|
// A 65538-byte match exceeds even the 65536-byte ring. Its input is already
// complete, so suspend only on output and never replay any copied bytes.
fn Inflater::copy64(self : Inflater) -> @codec_bytes.Status? raise Stop {
  while self.copy_left > 0 {
    if !self.ensure_space(1) {
      return Some(NeedMoreOutput)
    }
    let count = self.copy_left.min(self.window_size - self.pending)
    self.copy_match(self.copy_distance, count)
    self.copy_left -= count
  }
  self.state = Codes
  None
}
