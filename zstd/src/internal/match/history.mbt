///|
/// One byte buffer for retained history and the unfinished cutter block.
/// Tables use buffer-relative positions; only a full buffer rebases them.
pub struct History {
  priv mut data : FixedArray[Byte]
  priv mut start : Int32
  priv mut end : Int32
  priv window : Int32
  priv first : FixedArray[Int32]
  priv second : FixedArray[Int32]
}

///|
fn History::new(
  window : Int32,
  first : FixedArray[Int32],
  second : FixedArray[Int32],
) -> History {
  { data: [], start: 0, end: 0, window, first, second, }
}

///|
/// The backing bytes, including the unfinished block at `block_start()`.
pub fn History::buffer(self : History) -> FixedArray[Byte] {
  self.data
}

///|
/// Where the current cutter block begins in `buffer()`.
pub fn History::block_start(self : History) -> Int32 {
  self.start
}

///|
/// Capacity of the byte buffer; position tables are counted by the finder.
pub fn History::capacity(self : History) -> Int32 {
  self.data.length()
}

///|
fn History::limit(self : History) -> Int32 {
  // One window of slack amortizes the retained-window copy over at least
  // one window of input. Include one whole block to keep cuts deterministic.
  self.window + self.window + self.window.min(131072)
}

///|
/// Reserve space for the next whole cutter block before taking any of it.
/// Returns the cut, so a chain finder can preserve its ring slots and cursor.
fn History::prepare(self : History, block_max : Int32) -> Int32 {
  guard self.start + block_max > self.limit() else { return 0 }
  let cut = (self.start - self.window).max(0)
  // prepare runs with no unfinished block. Both ranges lie in valid data;
  // unsafe_blit has memmove semantics for their overlap.
  FixedArray::unsafe_blit(self.data, 0, self.data, cut, self.end - cut)
  self.start -= cut
  self.end -= cut
  rebase_positions(self.first, cut)
  rebase_positions(self.second, cut)
  cut
}

///|
fn rebase_positions(table : FixedArray[Int32], cut : Int32) -> Unit {
  for i in 0..<table.length() {
    table[i] = (table[i] - cut).max(-1)
  }
}

///|
fn History::grow(self : History, n : Int32) -> Unit {
  if self.end + n > self.data.length() {
    let size = (self.end + n)
      .max((self.data.length() * 2).max(1024))
      .min(self.limit())
    let grown = FixedArray::make(size, b'\x00')
    FixedArray::unsafe_blit(grown, 0, self.data, 0, self.end)
    self.data = grown
  }
}

///|
/// Copies caller input straight into the unfinished block. The caller's
/// cutter limits the total to the block size passed to `prepare`.
pub fn History::append(self : History, bytes : BytesView) -> Unit {
  self.grow(bytes.length())
  self.data.blit_from_bytesview(self.end, bytes)
  self.end += bytes.length()
}

///|
fn History::append_fixed(
  self : History,
  bytes : FixedArray[Byte],
  n : Int32,
) -> Unit {
  self.grow(n)
  FixedArray::unsafe_blit(self.data, self.end, bytes, 0, n)
  self.end += n
}

///|
/// Marks the current block encoded, after raw/RLE fallback has read it.
pub fn History::finish_block(self : History) -> Unit {
  self.start = self.end
}

///|
/// Forgets the frame's history, keeping the buffer's capacity: positions
/// are dropped from both tables, and matches compare only bytes below
/// `end`, so the bytes left in the buffer are never matched against. (A
/// wide literal copy may read them, into literals past those it keeps.)
fn History::reset(self : History) -> Unit {
  self.start = 0
  self.end = 0
  self.first.fill(-1)
  self.second.fill(-1)
}
