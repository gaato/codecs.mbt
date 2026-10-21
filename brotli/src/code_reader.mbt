// Reading one prefix code (RFC 7932 section 3.4 and 3.5), one unit at a
// time: a simple code is one unit; a complex code is one unit per code
// length code length and one per symbol code length (or repeat).

///|
priv enum CodePhase {
  /// About to read HSKIP and, for a simple code, the whole code.
  Start
  /// Reading the code length code lengths.
  CodeLengthLengths
  /// Reading the symbols' code lengths.
  SymbolLengths
}

///|
priv struct CodeReader {
  mut phase : CodePhase
  mut alphabet : Int32
  mut group : Group
  mut tree : Int32
  cl_lengths : FixedArray[Int32]
  cl_code : Group
  mut cl_index : Int32
  mut cl_space : Int32
  mut cl_count : Int32
  lengths : FixedArray[Int32]
  mut symbol : Int32
  mut space : Int32
  mut prev_len : Int32
  mut repeat : Int32
  mut repeat_len : Int32
}

///|
fn CodeReader::new() -> CodeReader {
  {
    phase: Start,
    alphabet: 0,
    group: Group::new(1),
    tree: 0,
    cl_lengths: FixedArray::make(18, 0),
    cl_code: Group::new(1),
    cl_index: 0,
    cl_space: 0,
    cl_count: 0,
    lengths: FixedArray::make(MAX_ALPHABET, 0),
    symbol: 0,
    space: 0,
    prev_len: 0,
    repeat: 0,
    repeat_len: 0,
  }
}

///|
/// Prepares to read the code of tree `tree` of `group` over `alphabet`
/// symbols.
fn CodeReader::start(
  self : CodeReader,
  alphabet : Int32,
  group : Group,
  tree : Int32,
) -> Unit {
  self.phase = Start
  self.alphabet = alphabet
  self.group = group
  self.tree = tree
}

///|
/// The bits a simple code spends on each symbol.
fn alphabet_bits(alphabet : Int32) -> Int32 {
  for bits = 0, v = alphabet - 1; v > 0; {
    continue bits + 1, v >> 1
  } nobreak {
    bits
  }
}

///|
/// One unit of the prefix code being read; true once its table is built.
fn Decoder::read_code(self : Decoder) -> Bool raise Stop {
  let code = self.code
  match code.phase {
    Start => {
      let hskip = self.read_bits(2)
      if hskip == 1 {
        self.read_simple_code()
        return true
      }
      code.cl_lengths.fill(0)
      code.cl_index = hskip
      code.cl_space = 32
      code.cl_count = 0
      code.phase = CodeLengthLengths
      false
    }
    CodeLengthLengths => {
      if self.nbits < 4 {
        self.refill()
      }
      let ix = self.acc & 15
      let bits = code_length_prefix_bits[ix]
      if bits > self.nbits {
        raise NeedInput
      }
      self.acc = self.acc >> bits
      self.nbits -= bits
      let v = code_length_prefix_value[ix]
      code.cl_lengths[code_length_order[code.cl_index]] = v
      code.cl_index += 1
      if v != 0 {
        code.cl_space -= 32 >> v
        code.cl_count += 1
      }
      if (v != 0 && code.cl_space <= 0) || code.cl_index == 18 {
        if !(code.cl_count == 1 || code.cl_space == 0) {
          raise corrupt("invalid code length code")
        }
        code.cl_code.reset(1, 18)
        if code.cl_count == 1 {
          for s in 0..<18 {
            if code.cl_lengths[s] != 0 {
              code.cl_code.single(0, s)
              break
            }
          }
        } else {
          code.cl_code.build(self.builder, 0, code.cl_lengths, 18)
        }
        code.lengths.fill(0, end=code.alphabet)
        code.symbol = 0
        code.space = 32768
        code.prev_len = 8
        code.repeat = 0
        code.repeat_len = 0
        code.phase = SymbolLengths
      }
      false
    }
    SymbolLengths => {
      let len = self.read_symbol(code.cl_code, 0)
      if len < 16 {
        code.repeat = 0
        if len != 0 {
          code.lengths[code.symbol] = len
          code.prev_len = len
          code.space -= 32768 >> len
        }
        code.symbol += 1
      } else {
        let extra_bits = if len == 16 { 2 } else { 3 }
        let extra = self.read_bits(extra_bits)
        let new_len = if len == 16 { code.prev_len } else { 0 }
        if code.repeat_len != new_len {
          code.repeat = 0
          code.repeat_len = new_len
        }
        let old = code.repeat
        if code.repeat > 0 {
          code.repeat = (code.repeat - 2) << extra_bits
        }
        code.repeat += extra + 3
        let delta = code.repeat - old
        if code.symbol + delta > code.alphabet {
          raise corrupt("code length repeat past the alphabet")
        }
        if new_len != 0 {
          code.lengths.fill(new_len, start=code.symbol, end=code.symbol + delta)
          code.space -= delta << (15 - new_len)
        }
        code.symbol += delta
      }
      if code.symbol < code.alphabet && code.space > 0 {
        return false
      }
      if code.space != 0 {
        raise corrupt("incomplete or oversubscribed prefix code")
      }
      code.group.build(self.builder, code.tree, code.lengths, code.alphabet)
      true
    }
  }
}

///|
/// A simple prefix code (section 3.4), after HSKIP.
fn Decoder::read_simple_code(self : Decoder) -> Unit raise Stop {
  let code = self.code
  let count = self.read_bits(2) + 1
  let bits = alphabet_bits(code.alphabet)
  let s0 = self.read_bits(bits)
  let s1 = if count > 1 { self.read_bits(bits) } else { 0 }
  let s2 = if count > 2 { self.read_bits(bits) } else { 0 }
  let s3 = if count > 3 { self.read_bits(bits) } else { 0 }
  let tree_select = if count == 4 { self.read_bits(1) } else { 0 }
  let symbols = [s0, s1, s2, s3]
  for i in 0..<count {
    if symbols[i] >= code.alphabet {
      raise corrupt("simple prefix code symbol out of range")
    }
    for j in 0..<i {
      if symbols[i] == symbols[j] {
        raise corrupt("simple prefix code repeats a symbol")
      }
    }
  }
  if count == 1 {
    code.group.single(code.tree, s0)
    return
  }
  let lengths = code.lengths
  lengths.fill(0, end=code.alphabet)
  match (count, tree_select) {
    (2, _) => {
      lengths[s0] = 1
      lengths[s1] = 1
    }
    (3, _) => {
      lengths[s0] = 1
      lengths[s1] = 2
      lengths[s2] = 2
    }
    (_, 0) => {
      lengths[s0] = 2
      lengths[s1] = 2
      lengths[s2] = 2
      lengths[s3] = 2
    }
    _ => {
      lengths[s0] = 1
      lengths[s1] = 2
      lengths[s2] = 3
      lengths[s3] = 3
    }
  }
  code.group.build(self.builder, code.tree, lengths, code.alphabet)
}
