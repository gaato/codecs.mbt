// Wasm's payload loop uses the producer's fixed-alphabet invariants to
// avoid repeated range checks. It pairs literal codes (at most 30 bits)
// and skips zero-width extras, preserving the same bit sequence.

///|
#cfg(target="wasm")
fn Encoder::write_compressed(
  self : Encoder,
  start : Int32,
  end : Int32,
  is_last : Bool,
) -> Bool {
  let w = self.writer
  let mb = self.meta_block
  // An uncompressed meta-block takes the bytes and at most 4 header bytes,
  // and the last one an empty last meta-block after it, 1 byte more.
  let budget = self.writer.position() +
    (end - start + 4 + (if is_last { 1 } else { 0 })) * 8
  w.write(1, if is_last { 1 } else { 0 })
  if is_last {
    w.write(1, 0)
  }
  write_length(w, end - start)
  if !is_last {
    w.write(1, 0)
  }
  // NBLTYPESL, NBLTYPESI and NBLTYPESD 1; NPOSTFIX and NDIRECT 0; context
  // mode LSB6; NTREESL and NTREESD 1.
  w.write(3, 0)
  w.write(6, 0)
  w.write(2, 0)
  w.write(2, 0)
  let cw = mb.code_writer
  cw.write_code(w, mb.lit_freqs, NUM_LITERALS, mb.lit_lengths, mb.lit_codes)
  cw.write_code(w, mb.cmd_freqs, MAX_ALPHABET, mb.cmd_lengths, mb.cmd_codes)
  cw.write_code(
    w,
    mb.dist_freqs,
    DISTANCE_ALPHABET,
    mb.dist_lengths,
    mb.dist_codes,
  )
  let data = self.data
  // Each literal's code and its length in one entry, `length | code << 4`.
  let lit = FixedArray::makei(NUM_LITERALS, b => {
    mb.lit_lengths[b] | (mb.lit_codes[b] << 4)
  })
  let mut pos = start
  // parse emits at most MAX_COMMANDS commands. Its symbols, insert/copy
  // codes and distance symbols index their respective fixed alphabets.
  for i in 0..<mb.count {
    if w.position() > budget {
      return false
    }
    let sym = mb.symbols.unsafe_get(i)
    w.write(mb.cmd_lengths.unsafe_get(sym), mb.cmd_codes.unsafe_get(sym))
    let cell = sym >> 6
    let ic = cell_insert_base.unsafe_get(cell) + ((sym >> 3) & 7)
    let cc = cell_copy_base.unsafe_get(cell) + (sym & 7)
    let insert_bits = insert_length_extra.unsafe_get(ic)
    if insert_bits > 0 {
      w.write(
        insert_bits,
        mb.inserts.unsafe_get(i) - insert_length_base.unsafe_get(ic),
      )
    }
    let copy_bits = copy_length_extra.unsafe_get(cc)
    if copy_bits > 0 {
      w.write(
        copy_bits,
        mb.copies.unsafe_get(i) - copy_length_base.unsafe_get(cc),
      )
    }
    let inserts = mb.inserts.unsafe_get(i)
    if w.position() + inserts * MAX_CODE_LENGTH <= budget {
      // The literals' codes, at most 15 bits each, all fit the budget: no
      // check between them can fail.
      let stop = pos + inserts
      let mut p = pos
      while p + 1 < stop {
        let first = lit.unsafe_get(data.unsafe_get(p).to_int())
        let second = lit.unsafe_get(data.unsafe_get(p + 1).to_int())
        let width = first & 15
        w.write(width + (second & 15), (first >> 4) | (second >> 4 << width))
        p += 2
      }
      if p < stop {
        let e = lit.unsafe_get(data.unsafe_get(p).to_int())
        w.write(e & 15, e >> 4)
      }
    } else {
      for p in pos..<(pos + inserts) {
        let e = lit[data[p].to_int()]
        w.write(e & 15, e >> 4)
        if w.position() > budget {
          return false
        }
      }
    }
    pos += mb.inserts.unsafe_get(i) + mb.copies.unsafe_get(i)
    let ds = mb.dist_symbols.unsafe_get(i)
    if ds >= 0 {
      w.write(mb.dist_lengths.unsafe_get(ds), mb.dist_codes.unsafe_get(ds))
      if ds >= 16 {
        w.write(distance_extra_bits(ds), mb.dist_extras.unsafe_get(i))
      }
    }
  }
  w.position() <= budget
}
