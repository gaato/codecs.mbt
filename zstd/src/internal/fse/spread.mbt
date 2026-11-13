// Where each symbol's states go in a table (RFC 8878 section 4.1.1). The
// decoder builds its tables from this placement and the encoder its own, so
// a stream one writes is a stream the other reads only if both place every
// symbol on the same states: one function does it for both.

///|
/// Places the symbols of `probs[0:count]`, a distribution over `1 << log`
/// states in which -1 stands for "less than 1", on the states of a table:
/// `symbols[state]` is the symbol of each state. The symbols of -1 take one
/// state each from the top down, in order; the others are spread from state
/// 0 in steps of `(size >> 1) + (size >> 3) + 3`, skipping those top states,
/// each taking as many states as its probability says.
///
/// False when the spread does not end back at state 0, where it ends when
/// the states add up to `1 << log`: only a corrupt table description could
/// give another distribution, and the decoder's reader refuses those first.
pub fn spread(
  probs : FixedArray[Int32],
  count : Int32,
  log : Int32,
  symbols : FixedArray[Byte],
) -> Bool {
  let size = 1 << log
  let mut high = size - 1
  for s in 0..<count {
    if probs[s] == -1 {
      symbols[high] = s.to_byte()
      high -= 1
    }
  }
  let step = (size >> 1) + (size >> 3) + 3
  let mask = size - 1
  let mut pos = 0
  for s in 0..<count {
    for _ in 0..<probs[s] {
      symbols[pos] = s.to_byte()
      pos = (pos + step) & mask
      while pos > high {
        pos = (pos + step) & mask
      }
    }
  }
  pos == 0
}
