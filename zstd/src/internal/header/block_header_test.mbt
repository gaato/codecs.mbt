///|
/// The block header as RFC 8878 section 3.1.1.2 describes it: bit 0 is
/// Last_Block, bits 1-2 Block_Type and bits 3-23 Block_Size, with the
/// decoder's checks in its order.
fn block_header_ref(
  value : Int32,
  block_max : Int32,
) -> Result[@header.BlockHeader, String] {
  let last = value % 2 == 1
  let block_type = value / 2 % 4
  let size = value / 8
  let (kind, too_large) : (@header.BlockType, String) = match block_type {
    0 => (Raw, "a raw block larger than the block limit")
    1 => (Rle, "an RLE block larger than the block limit")
    2 => (Compressed, "a compressed block larger than the block limit")
    _ => return Err("a block of the reserved type")
  }
  if size > block_max {
    Err(too_large)
  } else if block_type == 2 && size == 0 {
    Err("an empty compressed block")
  } else {
    Ok({ last, block_type: kind, size, })
  }
}

///|
fn block_header(
  value : Int32,
  block_max : Int32,
) -> Result[@header.BlockHeader, String] {
  @header.parse_block_header(value).bind(h => h.check(block_max))
}

///|
/// Native runs every 24-bit header, under the largest block limit; the
/// other targets, slower, every header whose size is a multiple of 61. The
/// next test covers the sizes near smaller limits.
#cfg(target="native")
const SIZE_STRIDE : Int32 = 1

///|
#cfg(not(target="native"))
const SIZE_STRIDE : Int32 = 61

///|
test "block headers: the 24-bit header space against the RFC" {
  for size = 0; size < 1 << 21; size = size + SIZE_STRIDE {
    for low in 0..<8 {
      let value = (size << 3) | low
      let actual = block_header(value, 1 << 17)
      if actual != block_header_ref(value, 1 << 17) {
        fail("header \{value}: \{Repr(actual)}")
      }
    }
  }
}

///|
test "block headers: sizes near the limits" {
  for block_max in [1, 1024, 1 << 16, 1 << 17] {
    let sizes = [0, 1, 2, 1000, block_max - 1, block_max, block_max + 1]
    for size in [..sizes, (1 << 21) - 1] {
      for low in 0..<8 {
        let value = (size << 3) | low
        assert_eq(
          block_header(value, block_max),
          block_header_ref(value, block_max),
        )
      }
    }
  }
  debug_inspect(
    @header.parse_block_header(0xFFFFFF),
    content=(
      #|Err("a block of the reserved type")
    ),
  )
  debug_inspect(
    block_header((1 << 17 << 3) | 0b101, 1 << 17),
    content=(
      #|Ok({ last: true, block_type: Compressed, size: 131072 })
    ),
  )
}
