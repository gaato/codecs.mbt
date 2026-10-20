// The tables every test vector builds, against the references of
// `fse_spec_wbtest.mbt` and `huffman_spec_wbtest.mbt`.

///|
/// Whether `table` is the reference table of a distribution: the one its
/// states give, each symbol's probability its number of states, with some
/// of the symbols in the last states taken as "less than 1" (their states
/// look the same as those of a probability of 1).
fn fse_matches_some_distribution(table : Fse) -> Bool raise {
  let cells = fse_cells(table)
  let size = cells.length()
  let counts = Array::make(256, 0)
  let mut symbols = 0
  for cell in cells {
    counts[cell.0] += 1
    symbols = symbols.max(cell.0 + 1)
  }
  let probs = counts[:symbols].to_owned()
  // "Less than 1" symbols take the last states going down in symbol order,
  // so the candidates are the runs of single-state symbols there.
  for low = 0; low <= size; low = low + 1 {
    if fse_reference(probs, table.log) is Some(expected) && expected == cells {
      check_fse_properties(probs, cells)
      return true
    }
    guard low < size else { break }
    let s = cells[size - 1 - low].0
    guard counts[s] == 1 && (low == 0 || s > cells[size - low].0) else { break }
    probs[s] = -1
  }
  false
}

///|
/// The explicit weights of a built Huffman table: each symbol's from its
/// code length, the last used symbol's left implied.
fn huffman_weights_of(huffman : Huffman) -> Array[Int32] {
  let weights = Array::make(256, 0)
  let mut last = 0
  for entry in huffman_table(huffman) {
    weights[entry.0] = huffman.max_bits + 1 - entry.1
    last = last.max(entry.0)
  }
  weights[:last].to_owned()
}

///|
/// Checks the tables `decoder` holds after a compressed block.
fn check_decoder_tables(decoder : Decoder) -> Unit raise {
  for table in [decoder.ll_table, decoder.of_table, decoder.ml_table] {
    if table is Some(table) && table.log > 0 {
      assert_true(fse_matches_some_distribution(table))
    }
  }
  let huffman = decoder.huffman
  if huffman.weight_table.log > 0 {
    assert_true(fse_matches_some_distribution(huffman.weight_table))
  }
  if decoder.huffman_valid {
    let weights = huffman_weights_of(huffman)
    let (max_bits, table) = huffman_reference(weights).unwrap()
    assert_eq(huffman.max_bits, max_bits)
    assert_eq(huffman_table(huffman), table)
    check_kraft(max_bits, table)
  }
}

///|
test "every vector's FSE and Huffman tables match the RFC" {
  let mut blocks = 0
  for v in vectors {
    let decoder = Decoder(max_window_bits=v.window_bits.max(10))
    // A compressed block's bytes come in one chunk and everything else a
    // byte at a time, so each step decodes at most one block; the tables
    // are checked after each step that does.
    let in_block = Ref(false)
    let next_in = () => {
      let wanted = match decoder.state {
        CompressedBlock => decoder.block_size - decoder.block_len
        RawBlock => decoder.remaining.to_int()
        _ => 1
      }
      wanted.max(1)
    }
    let check = (d : Decoder, _) => {
      if in_block.val && !(d.state is CompressedBlock) {
        check_decoder_tables(d)
        blocks += 1
      }
      in_block.val = d.state is CompressedBlock
    }
    let out = drive(
      decoder,
      v.input()[:],
      next_in~,
      next_out=() => 1 << 17,
      check~,
    )
    assert_eq(out.length(), v.size)
  }
  assert_true(blocks > 100)
}
