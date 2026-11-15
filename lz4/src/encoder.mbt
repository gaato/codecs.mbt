// The streaming encoder of LZ4 frames, as lz4's lz4frame.c writes them: the
// header, blocks of up to the block size (each stored uncompressed when
// compressing does not make it smaller), the end mark and the content
// checksum.

///|
/// History kept for linked blocks and dictionaries: the most a match
/// reaches back, and a byte.
const HISTORY : Int32 = 65536

///|
/// A streaming LZ4 frame encoder. It holds a block of input (64 KiB by
/// default), the 64 KiB before it for linked blocks or a dictionary, the
/// hash table and a block's output.
pub struct Encoder {
  priv acceleration : Int32
  priv block_size : BlockSize
  priv linked : Bool
  priv checksum : Bool
  priv block_checksum : Bool
  priv content_size : Int64?
  // The last 64 KiB of the dictionary, and its id for the header.
  priv dictionary : BytesView?
  priv dictionary_id : UInt32?
  // History, then the block being gathered at `pre`: `fill` bytes of it.
  priv buf : FixedArray[Byte]
  priv mut pre : Int32
  priv mut fill : Int32
  priv table : FixedArray[Int32]
  // The dictionary's table, which every independent block starts from.
  priv dict_table : FixedArray[Int32]
  // Output waiting: `out.pos` bytes, of which `out_pos` are handed out.
  priv out : Writer
  priv mut out_pos : Int32
  priv xxh : Xxh32
  priv mut taken : Int64
  priv mut started : Bool
  priv mut finished : Bool
  priv mut done : Bool
  priv mut failure : @codec.CodecError?
  priv mut consumed : Int32
  priv mut produced : Int32
}

///|
/// An encoder at the start of a frame.
///
/// - `acceleration`: lz4's (`lz4 --fast=N` is N + 1): 1, the default, is
///   `lz4 -1`; each step up searches less and compresses faster. Values
///   below 1 count as 1, above 65,537 as 65,537.
/// - `block_size`: the most input in a block, 64 KiB by default as lz4's
///   library has it (`lz4` the command uses 4 MiB, `-B7`).
/// - `linked`: whether a block's matches may reach into the 64 KiB before
///   it, which compresses small blocks better (true by default, as lz4's
///   library has it; `lz4` uses independent blocks, `-BI`). With
///   independent blocks and no dictionary, each block is the bytes lz4
///   writes for it.
/// - `checksum`: the frame ends with the XXH32 of its content (true by
///   default, as `lz4` writes it); `block_checksum` adds the XXH32 of each
///   block's stored bytes.
/// - `content_size`: written in the header, and the input must then be
///   exactly that long: `step` raises `ChecksumMismatch` once it has more,
///   or at `Finish` when it has less. A negative one counts as not given; 0
///   is held to but not written, as lz4's library has it (whose 0 means an
///   unknown size).
/// - `dictionary`: its last 64 KiB come before the frame's first block, or
///   before every block when they are independent, as `lz4 -D` uses one; a
///   decoder needs the same dictionary. `dictionary_id` is written in the
///   header to name it, as lz4's library can (the command writes none). The
///   encoder copies the dictionary's last 64 KiB.
pub fn Encoder::Encoder(
  acceleration~ : Int32 = 1,
  block_size~ : BlockSize = Max64KiB,
  linked~ : Bool = true,
  checksum~ : Bool = true,
  block_checksum~ : Bool = false,
  content_size? : Int64,
  dictionary? : BytesView,
  dictionary_id? : UInt32,
) -> Encoder {
  let dictionary = match dictionary {
    Some(d) if d.length() > 0 =>
      Some(d[(d.length() - MAX_DISTANCE).max(0):d.length()])
    _ => None
  }
  let content_size = match content_size {
    Some(size) if size >= 0 => Some(size)
    _ => None
  }
  let bs = block_size.bytes()
  let history = if linked || dictionary is Some(_) { HISTORY } else { 0 }
  let dict_table = match dictionary {
    Some(_) => FixedArray::make(TABLE_ENTRIES, -1)
    None => FixedArray::make(0, 0)
  }
  let e = {
    acceleration: acceleration.max(1).min(65537),
    block_size,
    linked,
    checksum,
    block_checksum,
    content_size,
    dictionary,
    dictionary_id,
    buf: FixedArray::make(history + bs, b'\x00'),
    pre: 0,
    fill: 0,
    table: FixedArray::make(TABLE_ENTRIES, 0),
    dict_table,
    out: Writer::new(frame_overhead() + bs),
    out_pos: 0,
    xxh: Xxh32::new(),
    taken: 0,
    started: false,
    finished: false,
    done: false,
    failure: None,
    consumed: 0,
    produced: 0,
  }
  if dictionary is Some(d) {
    e.buf.blit_from_bytesview(0, d)
    load_history(e.buf, 0, d.length(), e.dict_table)
  }
  // `start_frame` copies the dictionary in again.
  e.start_frame()
  e
}

///|
/// The most bytes around one block's data in a step's output: the header
/// (19), the block's size (4) and checksum (4), the end mark (4) and the
/// content checksum (4).
fn frame_overhead() -> Int32 {
  19 + 4 + 4 + 4 + 4
}

///|
/// The history the frame's first block starts with.
fn Encoder::start_frame(self : Encoder) -> Unit {
  match self.dictionary {
    Some(d) => {
      // Linked blocks' history slides over the dictionary: it is copied in
      // again for every frame.
      self.buf.blit_from_bytesview(0, d)
      self.pre = d.length()
      FixedArray::unsafe_blit(self.table, 0, self.dict_table, 0, TABLE_ENTRIES)
    }
    None => {
      // A cleared table, as lz4's: its entries point at the first byte,
      // which lz4 then tries as a candidate.
      self.pre = 0
      self.table.fill(0)
    }
  }
  self.fill = 0
}

///|
/// Back to the state of a new encoder with the same options; the buffers'
/// memory is kept.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.start_frame()
  self.out.pos = 0
  self.out_pos = 0
  self.xxh.reset()
  self.taken = 0
  self.started = false
  self.finished = false
  self.done = false
  self.failure = None
  self.consumed = 0
  self.produced = 0
}

///|
/// Bytes the encoder holds, the same from the first step to the last: the
/// block and its history, the hash tables (4 bytes an entry), and a block's
/// output with the header and footer, within
/// `encoder_memory_bound(block_size~)`.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.buf.length() +
  4 * (self.table.length() + self.dict_table.length()) +
  self.out.data.length()
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
/// Whether the frame has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Compresses from `input` into `output`. `Continue` takes input, `Flush`
/// writes what is held as a block, so that the output so far decodes to
/// the input so far, and `Finish` does so and ends the frame. Input that was
/// not taken (when the output is full) must be passed again, with the same
/// action. Answers `NeedMoreInput` once everything is taken and handed out,
/// `NeedMoreOutput` while output waits, `Done` once the frame has ended and
/// been handed out; after that, steps take no input and answer `Done`.
///
/// Raises only when the encoder was given `content_size` and the input does
/// not match it: `ChecksumMismatch`, once the input passes it (the bytes up
/// to it are taken as with `Continue`) or at `Finish` when it falls short.
/// The error sticks: later steps raise it again, taking and writing
/// nothing, until `reset`.
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
  if !self.started {
    self.started = true
    self.write_header()
  }
  let mut flushed = false
  for ;; {
    let n = (self.out.pos - self.out_pos).min(output.length() - self.produced)
    if n > 0 {
      @blit.into_view(output, self.produced, self.out.data, self.out_pos, n)
      self.out_pos += n
      self.produced += n
    }
    if self.out_pos < self.out.pos {
      return NeedMoreOutput
    }
    self.out.pos = 0
    self.out_pos = 0
    if self.finished {
      self.done = true
      return Done
    }
    let bs = self.block_size.bytes()
    if self.fill == bs {
      self.write_block()
      continue
    }
    let mut take = (input.length() - self.consumed).min(bs - self.fill)
    if self.content_size is Some(cs) {
      take = take.to_int64().min(cs - self.taken).to_int()
    }
    if take > 0 {
      let chunk = input[self.consumed:self.consumed + take]
      self.buf.blit_from_bytesview(self.pre + self.fill, chunk)
      if self.checksum {
        self.xxh.update_view(chunk)
      }
      self.fill += take
      self.consumed += take
      self.taken += take.to_int64()
      continue
    }
    if self.consumed < input.length() {
      let err = @codec.CodecError(
        ChecksumMismatch,
        "more input than the declared content size",
      )
      self.failure = Some(err)
      raise err
    }
    match action {
      Continue => return NeedMoreInput
      Flush if !flushed && self.fill > 0 => {
        flushed = true
        self.write_block()
      }
      Flush => return NeedMoreInput
      Finish => {
        if self.content_size is Some(cs) && self.taken < cs {
          let err = @codec.CodecError(
            ChecksumMismatch,
            "less input than the declared content size",
          )
          self.failure = Some(err)
          raise err
        }
        if self.fill > 0 {
          self.write_block()
        }
        self.out.le32(0)
        if self.checksum {
          self.out.le32(self.xxh.digest())
        }
        self.finished = true
      }
    }
  }
}

///|
/// The magic number and the frame descriptor.
fn Encoder::write_header(self : Encoder) -> Unit {
  let out = self.out
  out.le32(FRAME_MAGIC)
  let start = out.pos
  let flg = 0x40 |
    (if self.linked { 0 } else { 0x20 }) |
    (if self.block_checksum { 0x10 } else { 0 }) |
    (if self.content_size is Some(cs) && cs > 0 { 0x08 } else { 0 }) |
    (if self.checksum { 0x04 } else { 0 }) |
    (if self.dictionary_id is Some(_) { 0x01 } else { 0 })
  out.byte(flg)
  out.byte(self.block_size.code() << 4)
  if self.content_size is Some(cs) && cs > 0 {
    let cs = cs.reinterpret_as_uint64()
    out.le32(cs.to_uint())
    out.le32((cs >> 32).to_uint())
  }
  if self.dictionary_id is Some(id) {
    out.le32(id)
  }
  let hc = xxh32(out.data.unsafe_reinterpret_as_bytes()[start:out.pos]) >> 8
  out.byte((hc & 0xFF).reinterpret_as_int())
}

///|
/// Writes the input held as one block, compressed unless that does not
/// make it smaller, and keeps what the next block may reach back into.
fn Encoder::write_block(self : Encoder) -> Unit {
  let out = self.out
  let n = self.fill
  let start = self.pre
  let end = start + n
  let size_at = out.pos
  out.pos += 4
  let data_at = out.pos
  let independent = !self.linked
  let mode = if independent && self.dictionary is None {
    // From a cleared table, as lz4 compresses a block on its own.
    self.table.fill(0)
    {
      small: n < SMALL_LIMIT,
      check_low: false,
      acceleration: self.acceleration,
    }
  } else {
    if independent {
      FixedArray::unsafe_blit(self.table, 0, self.dict_table, 0, TABLE_ENTRIES)
    }
    { small: false, check_low: true, acceleration: self.acceleration, }
  }
  // lz4 gives its compressor room for one byte less than the block.
  let compressed = compress_into(
    self.buf,
    start,
    end,
    0,
    self.table,
    mode,
    out,
    data_at + n - 1,
  )
  let size = if compressed && out.pos - data_at < n {
    out.pos - data_at
  } else {
    FixedArray::unsafe_blit(out.data, data_at, self.buf, start, n)
    out.pos = data_at + n
    n | (1 << 31)
  }
  out.data[size_at] = (size & 0xFF).to_byte()
  out.data[size_at + 1] = ((size >> 8) & 0xFF).to_byte()
  out.data[size_at + 2] = ((size >> 16) & 0xFF).to_byte()
  out.data[size_at + 3] = ((size >> 24) & 0xFF).to_byte()
  if self.block_checksum {
    out.le32(xxh32(out.data.unsafe_reinterpret_as_bytes()[data_at:out.pos]))
  }
  self.fill = 0
  if self.linked {
    // The last 64 KiB stay as history; the table follows them down.
    let keep = end.min(HISTORY)
    let delta = end - keep
    if delta > 0 {
      FixedArray::unsafe_blit(self.buf, 0, self.buf, delta, keep)
      let table = self.table
      for i in 0..<table.length() {
        table[i] = (table[i] - delta).max(-1)
      }
    }
    self.pre = keep
  }
}
