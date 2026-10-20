// The encoder's view of the fixed tables of RFC 7932: from lengths and
// distances to codes, built from the decoder's tables in `tables.mbt`.

///|
/// Lengths below this have their insert length code in a table.
const INSERT_TABLE_SIZE : Int32 = 2114

///|
/// Lengths below this have their copy length code in a table.
const COPY_TABLE_SIZE : Int32 = 2118

///|
/// `table[v]` is the code whose range holds `v`, for `v < size`.
fn length_code_table(
  base : FixedArray[Int32],
  size : Int32,
) -> FixedArray[Byte] {
  let table = FixedArray::make(size, b'\x00')
  for code in 0..<base.length() {
    let end = if code + 1 < base.length() { base[code + 1] } else { size }
    for v in base[code]..<end.min(size) {
      table[v] = code.to_byte()
    }
  }
  table
}

///|
let insert_code_table : FixedArray[Byte] = length_code_table(
  insert_length_base,
  INSERT_TABLE_SIZE,
)

///|
let copy_code_table : FixedArray[Byte] = length_code_table(
  copy_length_base,
  COPY_TABLE_SIZE,
)

///|
/// The code whose range in `base` holds `v`, for `v` past the table.
fn length_code_above(base : FixedArray[Int32], v : Int32) -> Int32 {
  for code = base.length() - 1; code > 0; code = code - 1 {
    if base[code] <= v {
      return code
    }
  }
  0
}

///|
/// The insert length code of `len` (section 5).
fn insert_code(len : Int32) -> Int32 {
  if len < INSERT_TABLE_SIZE {
    insert_code_table[len].to_int()
  } else {
    length_code_above(insert_length_base, len)
  }
}

///|
/// The copy length code of `len`, at least 2 (section 5).
fn copy_code(len : Int32) -> Int32 {
  if len < COPY_TABLE_SIZE {
    copy_code_table[len].to_int()
  } else {
    length_code_above(copy_length_base, len)
  }
}

///|
/// The cell of the insert-and-copy alphabet that holds insert codes from
/// `8 * i` and copy codes from `8 * c`, with an explicit distance, at
/// `3 * i + c`.
let explicit_cells : FixedArray[Int32] = {
  let cells = FixedArray::make(9, 0)
  for cell in 2..<cell_insert_base.length() {
    cells[(cell_insert_base[cell] >> 3) * 3 + (cell_copy_base[cell] >> 3)] = cell
  }
  cells
}

///|
/// The insert-and-copy symbol of insert code `ic` and copy code `cc`. With
/// `last_distance`, the command reuses the last distance, implicitly when a
/// cell allows it (symbols below 128).
fn command_symbol(ic : Int32, cc : Int32, last_distance : Bool) -> Int32 {
  let cell = if last_distance && ic < 8 && cc < 16 {
    cc >> 3
  } else {
    explicit_cells[(ic >> 3) * 3 + (cc >> 3)]
  }
  (cell << 6) | ((ic & 7) << 3) | (cc & 7)
}

///|
/// The distance symbol of distance `dist` (at least 1), with NPOSTFIX and
/// NDIRECT 0 (section 4): `16 + 2 * (bits - 1) + hi` with `bits` extra bits.
fn distance_symbol(dist : Int32) -> Int32 {
  let x = dist + 3
  let bits = 30 - x.clz()
  let hi = (x >> bits) & 1
  16 + 2 * (bits - 1) + hi
}

///|
/// The extra bits of distance `dist` under `distance_symbol(dist)`.
fn distance_extra(dist : Int32) -> Int32 {
  let x = dist + 3
  let bits = 30 - x.clz()
  x - ((2 + ((x >> bits) & 1)) << bits)
}

///|
/// How many extra bits distance symbol `sym` (at least 16) takes.
fn distance_extra_bits(sym : Int32) -> Int32 {
  1 + ((sym - 16) >> 1)
}

///|
/// The fixed code of code length code lengths (section 3.5), inverted: for
/// each length 0..5, its code (bits in writing order) and its bit count.
let code_length_code : FixedArray[Int32] = {
  let codes = FixedArray::make(6, 0)
  for ix in 0..<16 {
    let bits = code_length_prefix_bits[ix]
    codes[code_length_prefix_value[ix]] = ix & ((1 << bits) - 1)
  }
  codes
}

///|
let code_length_code_bits : FixedArray[Int32] = {
  let bits = FixedArray::make(6, 0)
  for ix in 0..<16 {
    bits[code_length_prefix_value[ix]] = code_length_prefix_bits[ix]
  }
  bits
}
