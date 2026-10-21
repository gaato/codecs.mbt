// Writing one prefix code (RFC 7932 sections 3.4 and 3.5): a simple code
// for up to four used symbols, else a complex code whose code lengths are
// run-length coded and themselves prefix coded.

///|
/// Scratch space for writing prefix codes, shared by a meta-block's codes.
priv struct CodeWriter {
  used : FixedArray[Int32]
  // The run-length coded code lengths: symbols 0..17 and their extra bits.
  rle_symbols : FixedArray[Int32]
  rle_extra : FixedArray[Int32]
  mut rle_count : Int32
  cl_freqs : FixedArray[Int32]
  cl_lengths : FixedArray[Int32]
  cl_codes : FixedArray[Int32]
}

///|
fn CodeWriter::new() -> CodeWriter {
  {
    used: FixedArray::make(4, 0),
    rle_symbols: FixedArray::make(MAX_ALPHABET, 0),
    rle_extra: FixedArray::make(MAX_ALPHABET, 0),
    rle_count: 0,
    cl_freqs: FixedArray::make(18, 0),
    cl_lengths: FixedArray::make(18, 0),
    cl_codes: FixedArray::make(18, 0),
  }
}

///|
/// Builds the prefix code of the frequencies `freqs[0..alphabet)` into
/// `lengths` and `codes` (bit-reversed, ready to write) and writes it. A
/// code with no used symbol is written as the one-symbol code of symbol 0.
/// The one symbol of a one-symbol code takes no bits.
fn CodeWriter::write_code(
  self : CodeWriter,
  w : @bits.BitPacker,
  freqs : FixedArray[Int32],
  alphabet : Int32,
  lengths : FixedArray[Int32],
  codes : FixedArray[Int32],
) -> Unit {
  let mut count = 0
  for s in 0..<alphabet {
    if freqs[s] > 0 {
      if count < 4 {
        self.used[count] = s
      }
      count += 1
    }
  }
  @huffman.code_lengths(freqs, alphabet, MAX_CODE_LENGTH, lengths)
  if count > 4 {
    self.write_complex(w, lengths, alphabet)
  } else {
    let used = self.used
    if count == 0 {
      used[0] = 0
    }
    let count = count.max(1)
    if count == 1 {
      lengths[used[0]] = 0
    }
    // The decoder gives the listed symbols lengths in a fixed order, the
    // shortest first.
    for i in 1..<count {
      for j = i; j > 0 && lengths[used[j]] < lengths[used[j - 1]]; j = j - 1 {
        let t = used[j]
        used[j] = used[j - 1]
        used[j - 1] = t
      }
    }
    w.write(2, 1)
    w.write(2, count - 1)
    let bits = alphabet_bits(alphabet)
    for i in 0..<count {
      w.write(bits, used[i])
    }
    if count == 4 {
      w.write(1, if lengths[used[0]] == 1 { 1 } else { 0 })
    }
  }
  @huffman.canonical_codes(lengths, alphabet, codes)
}

///|
/// A complex prefix code (section 3.5) with the given code lengths.
fn CodeWriter::write_complex(
  self : CodeWriter,
  w : @bits.BitPacker,
  lengths : FixedArray[Int32],
  alphabet : Int32,
) -> Unit {
  // Lengths after the last non-zero one are not written: the decoder stops
  // once the code is complete.
  let mut num = alphabet
  while lengths[num - 1] == 0 {
    num -= 1
  }
  self.run_length_code(lengths, num)
  let cl_freqs = self.cl_freqs
  cl_freqs.fill(0)
  for i in 0..<self.rle_count {
    cl_freqs[self.rle_symbols[i]] += 1
  }
  // A one-symbol code length code is legal but codes in zero bits; give it
  // a second, unused symbol so that every code length code is complete.
  let mut distinct = 0
  for f in cl_freqs {
    if f > 0 {
      distinct += 1
    }
  }
  if distinct == 1 {
    cl_freqs[if cl_freqs[0] == 0 { 0 } else { 1 }] = 1
  }
  let cl_lengths = self.cl_lengths
  @huffman.code_lengths(cl_freqs, 18, 5, cl_lengths)
  @huffman.canonical_codes(cl_lengths, 18, self.cl_codes)
  let hskip = if cl_lengths[code_length_order[0]] != 0 ||
    cl_lengths[code_length_order[1]] != 0 {
    0
  } else if cl_lengths[code_length_order[2]] != 0 {
    2
  } else {
    3
  }
  let mut last = 17
  while cl_lengths[code_length_order[last]] == 0 {
    last -= 1
  }
  w.write(2, hskip)
  for i in hskip..<=last {
    let len = cl_lengths[code_length_order[i]]
    w.write(code_length_code_bits[len], code_length_code[len])
  }
  for i in 0..<self.rle_count {
    let sym = self.rle_symbols[i]
    w.write(cl_lengths[sym], self.cl_codes[sym])
    if sym == 16 {
      w.write(2, self.rle_extra[i])
    } else if sym == 17 {
      w.write(3, self.rle_extra[i])
    }
  }
}

///|
fn CodeWriter::push(self : CodeWriter, sym : Int32, extra : Int32) -> Unit {
  self.rle_symbols[self.rle_count] = sym
  self.rle_extra[self.rle_count] = extra
  self.rle_count += 1
}

///|
/// Reverses the symbols pushed from `start`: a run's repeat codes are
/// worked out least significant first and read most significant first.
fn CodeWriter::reverse_from(self : CodeWriter, start : Int32) -> Unit {
  for i = start, j = self.rle_count - 1; i < j; i = i + 1, j = j - 1 {
    let s = self.rle_symbols[i]
    self.rle_symbols[i] = self.rle_symbols[j]
    self.rle_symbols[j] = s
    let e = self.rle_extra[i]
    self.rle_extra[i] = self.rle_extra[j]
    self.rle_extra[j] = e
  }
}

///|
/// Run-length codes `lengths[0..num)` with code length symbols 0..17, as
/// the reference encoder does: 16 repeats the previous non-zero length and
/// 17 repeats zero, consecutive repeat codes compounding (section 3.5).
fn CodeWriter::run_length_code(
  self : CodeWriter,
  lengths : FixedArray[Int32],
  num : Int32,
) -> Unit {
  self.rle_count = 0
  let mut prev = 8
  let mut i = 0
  while i < num {
    let value = lengths[i]
    let mut reps = 1
    while i + reps < num && lengths[i + reps] == value {
      reps += 1
    }
    i += reps
    if value == 0 {
      if reps == 11 {
        self.push(0, 0)
        reps -= 1
      }
      if reps < 3 {
        for _ in 0..<reps {
          self.push(0, 0)
        }
      } else {
        let start = self.rle_count
        reps -= 3
        for ;; {
          self.push(17, reps & 7)
          reps = reps >> 3
          if reps == 0 {
            break
          }
          reps -= 1
        }
        self.reverse_from(start)
      }
    } else {
      if prev != value {
        self.push(value, 0)
        reps -= 1
      }
      if reps == 7 {
        self.push(value, 0)
        reps -= 1
      }
      if reps < 3 {
        for _ in 0..<reps {
          self.push(value, 0)
        }
      } else {
        let start = self.rle_count
        reps -= 3
        for ;; {
          self.push(16, reps & 3)
          reps = reps >> 2
          if reps == 0 {
            break
          }
          reps -= 1
        }
        self.reverse_from(start)
      }
      prev = value
    }
  }
}
