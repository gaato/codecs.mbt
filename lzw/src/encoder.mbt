// The streaming LZW encoder.
//
// The table maps (code, byte) to the code extending it, in a hash table of
// twice the format's codes, probed linearly. Codes are packed into `out`,
// which a step hands out before it takes more input. When the table fills,
// GIF's and TIFF's encoders clear it as giflib and libtiff do; .Z's keeps
// it and clears it when the compression ratio drops, as compress does.

///|
/// compress checks the ratio every this many bytes of input.
const CHECK_GAP : Int32 = 10000

///|
/// A streaming LZW encoder for one of the formats of `Format`.
pub struct Encoder {
  priv format : Format
  // The table: keys `code << 8 | byte` (-1 for none) and their codes.
  priv keys : FixedArray[Int32]
  priv vals : FixedArray[UInt16]
  priv mask : Int32
  priv shift : Int32
  // Codes defined so far and the width; codes written since the last clear.
  priv mut next : Int32
  priv mut bits : Int32
  priv mut codes : Int32
  // The string being matched, as a code, or -1 before the first byte.
  priv mut current : Int32
  // Bits not yet written, and .Z's run of codes since its last padding.
  priv mut acc : UInt32
  priv mut nbits : Int32
  priv mut run : Int32
  // .Z's ratio check, once the table is full.
  priv mut taken : Int64
  priv mut written : Int64
  priv mut checkpoint : Int64
  priv mut ratio : Int64
  // Output waiting: `out[out_pos:out_len]`.
  priv out : FixedArray[Byte]
  priv mut out_pos : Int32
  priv mut out_len : Int32
  priv mut started : Bool
  priv mut finished : Bool
  priv mut done : Bool
  priv mut failure : @codec.CodecError?
  // An error found with output still waiting: raised once it is handed out.
  priv mut pending : @codec.CodecError?
  priv mut consumed : Int32
  priv mut produced : Int32
}

///|
/// An encoder of `format`. GIF, TIFF and PDF streams begin with a clear
/// code and end with the end code; .Z begins with its header. With
/// `Format::gif(n)` for `n` under 8, every input byte must be under
/// `1 << n`.
pub fn Encoder::Encoder(format : Format) -> Encoder {
  let entries = 1 << format.max_bits
  let e = {
    format,
    keys: FixedArray::make(entries * 2, -1),
    vals: FixedArray::make(entries * 2, 0),
    mask: entries * 2 - 1,
    shift: 32 - (format.max_bits + 1),
    next: 0,
    bits: 0,
    codes: 0,
    current: -1,
    acc: 0,
    nbits: 0,
    run: 0,
    taken: 0,
    written: 0,
    checkpoint: CHECK_GAP.to_int64(),
    ratio: 0,
    out: FixedArray::make(256, b'\x00'),
    out_pos: 0,
    out_len: 0,
    started: false,
    finished: false,
    done: false,
    failure: None,
    pending: None,
    consumed: 0,
    produced: 0,
  }
  e.clear_table()
  e
}

///|
/// Back to no codes past the literals, at the initial width.
fn Encoder::clear_table(self : Encoder) -> Unit {
  self.keys.fill(-1)
  self.next = self.format.first_code()
  self.bits = self.format.initial_bits()
  self.codes = 0
}

///|
/// Back to the state of a new encoder; the table's memory is kept.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.clear_table()
  self.current = -1
  self.acc = 0
  self.nbits = 0
  self.run = 0
  self.taken = 0
  self.written = 0
  self.checkpoint = CHECK_GAP.to_int64()
  self.ratio = 0
  self.out_pos = 0
  self.out_len = 0
  self.started = false
  self.finished = false
  self.done = false
  self.failure = None
  self.pending = None
  self.consumed = 0
  self.produced = 0
}

///|
/// Bytes the encoder holds, the same from the first step to the last: the
/// hash table (twice the format's codes, 6 bytes a slot) and 256 bytes of
/// output (`encoder_memory_bound(format)`).
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.keys.length() * 4 + self.vals.length() * 2 + self.out.length()
}

///|
/// Input bytes the latest `step` consumed.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.consumed
}

///|
/// Output bytes the latest `step` wrote.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.produced
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Writes `n` bits of `code`.
fn Encoder::put(self : Encoder, code : Int32, n : Int32) -> Unit {
  let c = code.reinterpret_as_uint()
  if self.format.msb_first {
    self.acc = (self.acc << n) | c
    self.nbits += n
    while self.nbits >= 8 {
      self.out[self.out_len] = (self.acc >> (self.nbits - 8)).to_byte()
      self.out_len += 1
      self.nbits -= 8
      self.acc = self.acc & ((1U << self.nbits) - 1)
    }
  } else {
    self.acc = self.acc | (c << self.nbits)
    self.nbits += n
    while self.nbits >= 8 {
      self.out[self.out_len] = (self.acc & 0xFF).to_byte()
      self.out_len += 1
      self.acc = self.acc >> 8
      self.nbits -= 8
    }
  }
}

///|
/// Writes a code at the width the decoder will read it at, widening first,
/// and for .Z padding the run that a change of width ends.
fn Encoder::write_code(self : Encoder, code : Int32) -> Unit {
  self.widen()
  self.put(code, self.bits)
  self.codes += 1
  self.run += 1
}

///|
/// The width the decoder reads the next code at: it widens as the codes
/// written since the last clear make the encoder's next code reach (or pass)
/// a power of two.
fn Encoder::widen(self : Encoder) -> Unit {
  let bits = self.format.width(self.bits, self.format.first_code() + self.codes)
  if bits != self.bits {
    self.pad_run(self.bits)
    self.bits = bits
  }
}

///|
/// .Z's padding where a run of codes of width `old` ends: zero bits to the
/// end of its group of eight codes, as compress writes them.
fn Encoder::pad_run(self : Encoder, old : Int32) -> Unit {
  guard self.format.unix else { return }
  let left = (8 - self.run % 8) % 8
  for _ in 0..<left {
    self.put(0, old)
  }
  self.run = 0
}

///|
/// Writes the clear code and clears the table.
fn Encoder::write_clear(self : Encoder) -> Unit {
  self.widen()
  self.put(self.format.clear_code(), self.bits)
  self.run += 1
  self.pad_run(self.bits)
  self.clear_table()
}

///|
/// Takes `input[from:from + count]`, extending the current string while the
/// table has it and writing it out where it does not. Gives the bytes
/// taken: fewer than `count` when a byte a GIF minimum code size under 8
/// cannot code stops it. The table and the string stay in locals.
fn Encoder::take_run(
  self : Encoder,
  input : BytesView,
  from : Int32,
  count : Int32,
) -> Int32 {
  let limit = 1 << self.format.literal_bits
  let keys = self.keys
  let vals = self.vals
  let mask = self.mask
  let shift = self.shift
  let mut current = self.current
  for i in 0..<count {
    let b = input.unsafe_get(from + i).to_int()
    if b >= limit {
      self.current = current
      return i
    }
    self.taken += 1
    if current < 0 {
      current = b
      continue
    }
    let key = (current << 8) | b
    // The slots are a power of two, and the table is at most half full.
    let mut h = ((key.reinterpret_as_uint() * 0x9E3779B1U) >> shift).reinterpret_as_int()
    let mut found = -1
    for ;; {
      let k = keys.unsafe_get(h)
      if k == key {
        found = vals.unsafe_get(h).to_int()
        break
      }
      if k < 0 {
        break
      }
      h = (h + 1) & mask
    }
    if found >= 0 {
      current = found
      continue
    }
    self.miss(current, key, h)
    current = b
  }
  self.current = current
  count
}

///|
/// The string `code` ends where its extension `key` is not in the table:
/// `code` is written, and `key` defined in the empty slot `slot` the search
/// stopped at, unless the table is full (then GIF and TIFF clear it, and .Z
/// checks its ratio).
fn Encoder::miss(
  self : Encoder,
  code : Int32,
  key : Int32,
  slot : Int32,
) -> Unit {
  self.write_code(code)
  let format = self.format
  if format.unix {
    if self.next < format.table_limit() {
      self.add_code(key, slot)
    } else if format.block_mode && self.taken >= self.checkpoint {
      self.check_ratio()
    }
  } else if self.next >= self.clear_at() {
    self.write_clear()
  } else {
    self.add_code(key, slot)
  }
}

///|
/// Defines the next code as `key`, in `slot`.
fn Encoder::add_code(self : Encoder, key : Int32, slot : Int32) -> Unit {
  self.keys[slot] = key
  self.vals[slot] = self.next.to_uint16()
  self.next += 1
}

///|
/// Where GIF's and TIFF's tables are cleared: giflib clears GIF's when the
/// next code would be 4095, libtiff TIFF's when it would be 4093 (with
/// early change, 4094 would be the last a 12-bit code could still widen
/// past).
fn Encoder::clear_at(self : Encoder) -> Int32 {
  if self.format.early_change {
    4093
  } else {
    4095
  }
}

///|
/// compress's check, every 10,000 bytes once the table is full: the table
/// is cleared when the ratio of input to output, with 8 fractional bits,
/// has dropped since the last check.
fn Encoder::check_ratio(self : Encoder) -> Unit {
  self.checkpoint = self.taken + CHECK_GAP.to_int64()
  let out = self.written + (self.out_len + self.nbits / 8).to_int64()
  let ratio = if out == 0L { 0x7FFFFFFFL } else { (self.taken << 8) / out }
  if ratio >= self.ratio {
    self.ratio = ratio
  } else {
    self.ratio = 0
    self.write_clear()
  }
}

///|
/// Compresses from `input` into `output`. `Continue` takes input and
/// `Finish` ends the stream; LZW has no way to flush, so `Flush` raises
/// `Unsupported`. Input that was not taken (when the output is full) must
/// be passed again, with the same action. Answers `NeedMoreInput` once
/// everything is taken and handed out, `NeedMoreOutput` while output waits,
/// `Done` once the stream has ended and been handed out.
///
/// Raises `Unsupported` for `Flush`, and for a byte a GIF minimum code
/// size under 8 cannot code, once the output of the bytes before it is
/// handed out (answering `NeedMoreOutput` while it does not fit); the error
/// sticks until `reset`.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : @codec_bytes.EncodeAction,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.consumed = 0
  self.produced = 0
  if self.failure is Some(err) {
    raise err
  }
  if self.done {
    return Done
  }
  if action is Flush {
    let err = @codec.CodecError(Unsupported, "LZW cannot flush")
    self.failure = Some(err)
    raise err
  }
  if !self.started {
    self.started = true
    if self.format.unix {
      self.out[0] = b'\x1F'
      self.out[1] = b'\x9D'
      self.out[2] = (self.format.max_bits |
      (if self.format.block_mode { 0x80 } else { 0 })).to_byte()
      self.out_len = 3
    } else {
      self.write_clear()
    }
  }
  for ;; {
    let n = (self.out_len - self.out_pos).min(output.length() - self.produced)
    for i in 0..<n {
      output[self.produced + i] = self.out[self.out_pos + i]
    }
    self.out_pos += n
    self.produced += n
    if self.out_pos < self.out_len {
      return NeedMoreOutput
    }
    if self.pending is Some(err) {
      // The output before the error is all handed out.
      self.failure = Some(err)
      raise err
    }
    self.written += self.out_len.to_int64()
    self.out_pos = 0
    self.out_len = 0
    if self.finished {
      self.done = true
      return Done
    }
    // A step's bytes fill `out` by at most a code and a clear with .Z's
    // padding each: well under its 256 bytes, so take 64 at a time.
    let take = (input.length() - self.consumed).min(64)
    if take > 0 {
      let took = self.take_run(input, self.consumed, take)
      self.consumed += took
      if took < take {
        let b = input[self.consumed].to_int()
        // Raised after the output of the bytes before it, which `take_run`
        // may have written, is handed out.
        self.pending = Some(
          @codec.CodecError(
            Unsupported,
            "a byte of \{b}, which a minimum code size of \{self.format.literal_bits} cannot code",
          ),
        )
      }
      continue
    }
    match action {
      Finish => {
        if self.current >= 0 {
          self.write_code(self.current)
          self.current = -1
        }
        if !self.format.unix {
          self.write_code(self.format.end_code())
        }
        if self.nbits > 0 {
          self.put(0, 8 - self.nbits)
        }
        self.finished = true
      }
      _ => return NeedMoreInput
    }
  }
}
