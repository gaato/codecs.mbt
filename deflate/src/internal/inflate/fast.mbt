// The fast path: literals and matches with the bit reader, the input and
// the window in locals, as zlib's inflate_fast does, on every target. It runs
// while the input holds enough bytes for a whole unit and the window has room
// for a match, so that no unit can run out inside: then it judges each unit
// exactly as `codes_unit` would. The bits are held in an `Int` of at most 30
// bits, refilled two bytes at a time below 15 (a 64-bit word would be a
// BigInt on JavaScript).

///|
/// The input bytes the fast path needs in hand: a unit reads at most 7 (two
/// before its literal/length code, one for the length's extra bits, two
/// before the distance code, two for its extra bits).
const FAST_INPUT : Int32 = 8

///|
/// Whether the fast path may run: no byte of the step's input is kept aside,
/// the input holds a whole unit, and the window has room for a match without
/// wrapping or overwriting output not yet handed out. Between units the bit
/// reader holds fewer than 8 bits.
fn Inflater::can_go_fast(self : Inflater) -> Bool {
  self.stash_pos == self.stash_len &&
  self.view.length() - self.in_pos >= FAST_INPUT &&
  self.pending <= WINDOW_SIZE - MAX_MATCH &&
  self.wpos <= WINDOW_SIZE - MAX_MATCH
}

///|
/// Decodes units while `can_go_fast` holds, up to the end of the block. The
/// whole bytes it read ahead are given back before it returns, so that the
/// bit reader again holds fewer than 8 bits, all from this step's input.
fn Inflater::go_fast(self : Inflater) -> Unit raise Stop {
  let data = self.view.data()
  let base = self.view.start_offset()
  let last = base + self.view.length() - FAST_INPUT
  let lit = self.lit
  let dist = self.dist
  let ring = self.ring
  let dictionary = self.dictionary
  let start = self.wpos
  // Units start while `wpos` is at most this: room for a match in the ring
  // before its end, and before the output not yet handed out.
  let limit = (WINDOW_SIZE - MAX_MATCH).min(
    start + (WINDOW_SIZE - MAX_MATCH - self.pending),
  )
  // How far back a distance may reach into the output: `filled` plus the
  // bytes this call wrote, which never wrap the ring.
  let reach = self.filled - start
  let mut pos = base + self.in_pos
  let mut acc = self.acc
  let mut nbits = self.nbits
  let mut wpos = start
  let mut error = ""
  // SAFETY: every `unsafe_get` of `data` is below `pos + 7 <= last + 7`,
  // inside the view; `wpos + 258 <= WINDOW_SIZE` before each unit bounds the
  // ring's writes, and a match's source lies `distance <= wpos + reach`
  // bytes back; table indexes are masked to the root or are links that
  // `decorate` made inside the table.
  while pos <= last && wpos <= limit {
    if nbits < 15 {
      acc = acc |
        (data.unsafe_get(pos).to_int() << nbits) |
        (data.unsafe_get(pos + 1).to_int() << (nbits + 8))
      pos += 2
      nbits += 16
    }
    let mut entry = lit.unsafe_get(acc & ((1 << LITERAL_ROOT_BITS) - 1))
    if (entry & KIND_MASK) == KIND_LINK {
      entry = lit.unsafe_get(
        (entry >> 16) +
        ((acc >> LITERAL_ROOT_BITS) & ((1 << ((entry >> 4) & 15)) - 1)),
      )
    }
    acc = acc >> (entry & 15)
    nbits -= entry & 15
    let kind = entry & KIND_MASK
    if kind == KIND_LITERAL {
      ring.unsafe_set(wpos, (entry >> 16).to_byte())
      wpos += 1
      continue
    }
    if kind != KIND_BASE {
      if kind == KIND_END_OF_BLOCK {
        self.end_block()
      } else {
        error = invalid_literal
      }
      break
    }
    let extra = (entry >> 4) & 15
    if nbits < extra {
      acc = acc | (data.unsafe_get(pos).to_int() << nbits)
      pos += 1
      nbits += 8
    }
    let length = (entry >> 16) + (acc & ((1 << extra) - 1))
    acc = acc >> extra
    nbits -= extra
    if nbits < 15 {
      acc = acc |
        (data.unsafe_get(pos).to_int() << nbits) |
        (data.unsafe_get(pos + 1).to_int() << (nbits + 8))
      pos += 2
      nbits += 16
    }
    let mut d = dist.unsafe_get(acc & ((1 << DISTANCE_ROOT_BITS) - 1))
    if (d & KIND_MASK) == KIND_LINK {
      d = dist.unsafe_get(
        (d >> 16) + ((acc >> DISTANCE_ROOT_BITS) & ((1 << ((d >> 4) & 15)) - 1)),
      )
    }
    acc = acc >> (d & 15)
    nbits -= d & 15
    if (d & KIND_MASK) != KIND_BASE {
      error = invalid_distance
      break
    }
    let dextra = (d >> 4) & 15
    if nbits < dextra {
      acc = acc | (data.unsafe_get(pos).to_int() << nbits)
      pos += 1
      nbits += 8
      if nbits < dextra {
        acc = acc | (data.unsafe_get(pos).to_int() << nbits)
        pos += 1
        nbits += 8
      }
    }
    let distance = (d >> 16) + (acc & ((1 << dextra) - 1))
    acc = acc >> dextra
    nbits -= dextra
    if distance > wpos + reach {
      // Before the output: into the dictionary, which only a stream that
      // has not yet written 32 KiB reaches, so the ring has not wrapped.
      if distance > wpos + reach + dictionary.length() {
        error = "a distance reaches before the start of the data"
        break
      }
      for _ in 0..<length {
        let back = distance - (wpos + reach)
        ring.unsafe_set(
          wpos,
          if back > 0 {
            dictionary[dictionary.length() - back]
          } else {
            ring.unsafe_get(wpos - distance)
          },
        )
        wpos += 1
      }
      continue
    }
    let from = wpos - distance
    if from < 0 {
      // The source wraps around the end of the ring.
      for i in 0..<length {
        ring.unsafe_set(wpos + i, ring.unsafe_get((from + i) & WINDOW_MASK))
      }
    } else if distance >= length {
      if length > 32 {
        FixedArray::unsafe_blit(ring, wpos, ring, from, length)
      } else {
        for i in 0..<length {
          ring.unsafe_set(wpos + i, ring.unsafe_get(from + i))
        }
      }
    } else {
      // Overlapping: each byte may repeat one this match wrote.
      for i in 0..<length {
        ring.unsafe_set(wpos + i, ring.unsafe_get(from + i))
      }
    }
    wpos += length
  }
  // Give back the whole bytes read ahead: all of them came from this step's
  // input, since the bit reader held fewer than 8 bits on entry.
  let ahead = nbits >> 3
  pos -= ahead
  nbits -= ahead << 3
  self.in_pos = pos - base
  self.acc = acc & ((1 << nbits) - 1)
  self.nbits = nbits
  let written = wpos - start
  self.wpos = wpos & WINDOW_MASK
  self.pending += written
  self.filled = (self.filled + written).min(WINDOW_SIZE)
  if self.state is Done {
    // The final block ended: what is left of its last byte is padding.
    self.align()
  }
  if error != "" {
    raise Fail(Corrupt, error)
  }
}
