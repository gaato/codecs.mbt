// The streaming encoder.
//
// Input is copied into `data`, a buffer that keeps the window of past input
// (for backward references) and the input not encoded yet, at most one
// meta-block of it. A full meta-block's worth is encoded as soon as it is
// there; `Flush` and `Finish` encode whatever is buffered. Compressed bytes
// wait in the bit writer until the caller's buffer takes them, and no more
// input is taken while they wait: memory stays bounded whatever the caller
// passes.

///|
/// The first allocation of the input buffer; it doubles as input grows.
const INITIAL_BUFFER : Int32 = 1024

///|
/// A streaming Brotli encoder (RFC 7932). Quality 4 uses lazy LZ77 and one
/// prefix code per category. Qualities 5..9 use the reference's hashers,
/// static dictionary and context modelling. Input and output chunks may
/// have any size; memory stays within `encoder_memory_bound`.
pub struct Encoder {
  // The LZ77 dictionary matches may copy from.
  priv dictionary : Dictionary?
  priv window_bits : Int32
  // The longest distance: the window less 16 bytes (section 9.1).
  priv max_distance : Int32
  // The input buffer: `data[0..data_len)` is past input (the window) up to
  // `block_start`, then input not encoded yet. It grows up to `data_max`,
  // then slides down.
  priv mut data : FixedArray[Byte]
  priv mut data_len : Int32
  priv mut block_start : Int32
  priv data_max : Int32
  priv matcher : @lz77.Matcher
  // The distance of the latest `longest_match`.
  priv mut found_dist : Int32
  priv meta_block : MetaBlock
  // The last four distances, as the decoder keeps them.
  priv dist_ring : FixedArray[Int32]
  priv mut dist_ring_index : Int32
  // Output: complete bytes of `writer` wait for the caller.
  priv writer : @bits.BitPacker
  priv mut header_written : Bool
  priv mut flush_requested : Bool
  priv mut finish_requested : Bool
  priv mut emitted_final : Bool
  priv mut done : Bool
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
  // Keep quality 4's hot fields at their existing offsets.
  priv quality : Int32
  priv size_hint : Int64
  priv mut ref_hint : Int64
  priv mut ref_hasher : RefHasher?
  priv ref_commands : Array[RefCommand]?
  priv ref_distances : FixedArray[Int32]
  priv ref_saved_distances : FixedArray[Int32]
  priv mut ref_batch : FixedArray[Byte]
  priv mut ref_ring : FixedArray[Byte]
  priv mut ref_batch_len : Int32
  priv mut ref_batch_pos : Int32
  priv mut ref_processed : Int32
  priv mut ref_offset : Int64
  priv mut ref_insert : Int32
  priv mut ref_literals : Int32
}

///|
/// An encoder at the start of a stream, with a window of
/// `1 << window_bits` bytes (clamped to 10..24). The default 22 is the
/// reference encoder's; a decoder needs up to that much memory.
/// `quality` defaults to 4 and is clamped to 0..11; 0..3 use 4, and
/// 10..11 use 9.
///
/// `size_hint` steers parameter selection at qualities 5..9. It is not
/// written to the stream or checked: a wrong hint still produces valid
/// output, which may differ. It is clamped to 0..1 GiB; zero, like an
/// omitted hint, uses the reference CLI's stdin mode. With a positive
/// known size, output matches its named-file mode at the same window.
/// Without a hint, input is processed on a fixed 512 KiB read schedule,
/// independent of caller chunks. Quality 4 ignores the hint.
///
/// With `dictionary`, a match may copy from it as RFC 9841 section 3.2 has
/// it, as `brotli -D` writes and RFC 9842's `dcb` coding reads: at a
/// distance past the window's reach, however far into the stream. A
/// decoder needs the same dictionary. The dictionary keeps the index the
/// encoder searches it with, built the first time and shared by every
/// encoder given it (`Dictionary::memory_usage`).
pub fn Encoder::Encoder(
  quality~ : Int32 = 4,
  size_hint? : Int64,
  window_bits~ : Int32 = 22,
  dictionary? : Dictionary,
) -> Encoder {
  let window_bits = window_bits.clamp(min=10, max=24)
  let window = 1 << window_bits
  let quality = quality.clamp(min=0, max=11)
  let quality = if quality < 4 { 4 } else { quality.min(9) }
  let size_hint = if quality == 4 {
    0L
  } else {
    size_hint.unwrap_or(0L).clamp(min=0L, max=1073741824L)
  }
  // Room to slide by at least a quarter window (or a meta-block) at a time.
  let slack = (window >> 2).max(BLOCK_SIZE)
  {
    quality,
    size_hint,
    ref_hint: size_hint,
    ref_hasher: None,
    ref_commands: if quality == 4 {
      None
    } else {
      Some(Array())
    },
    ref_distances: if quality == 4 {
      []
    } else {
      [4, 11, 15, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    },
    ref_saved_distances: if quality == 4 {
      []
    } else {
      [4, 11, 15, 16]
    },
    ref_batch: [],
    ref_ring: [],
    ref_batch_len: 0,
    ref_batch_pos: 0,
    ref_processed: 0,
    ref_offset: 0L,
    ref_insert: 0,
    ref_literals: 0,
    window_bits,
    dictionary,
    max_distance: window - 16,
    data: FixedArray::make(0, b'\x00'),
    data_len: 0,
    block_start: 0,
    data_max: if quality == 4 {
      window - 16 + slack + BLOCK_SIZE
    } else {
      window - 16 + ref_max_meta(quality, window_bits) + 524288 + 8
    },
    matcher: @lz77.Matcher(hash_bits=window_bits.min(15)),
    found_dist: 0,
    meta_block: MetaBlock::new(),
    dist_ring: [16, 15, 11, 4],
    dist_ring_index: 0,
    writer: @bits.BitPacker(),
    header_written: false,
    flush_requested: false,
    finish_requested: false,
    emitted_final: false,
    done: false,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream with the same quality, window, dictionary and hint.
/// Releases input and reference-matcher buffers; quality 4 keeps its tables.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.ref_hint = self.size_hint
  self.ref_hasher = None
  if self.ref_commands is Some(commands) {
    commands.clear()
  }
  if self.quality != 4 {
    for i, d in [4, 11, 15, 16] {
      self.ref_distances[i] = d
      self.ref_saved_distances[i] = d
    }
  }
  self.ref_batch = []
  self.ref_ring = []
  self.ref_batch_len = 0
  self.ref_batch_pos = 0
  self.ref_processed = 0
  self.ref_offset = 0L
  self.ref_insert = 0
  self.ref_literals = 0
  self.data = FixedArray::make(0, b'\x00')
  self.data_len = 0
  self.block_start = 0
  self.matcher.reset()
  self.dist_ring[0] = 16
  self.dist_ring[1] = 15
  self.dist_ring[2] = 11
  self.dist_ring[3] = 4
  self.dist_ring_index = 0
  self.writer.reset()
  self.header_written = false
  self.flush_requested = false
  self.finish_requested = false
  self.emitted_final = false
  self.done = false
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Input bytes the latest `step` took.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.step_produced
}

///|
/// Bytes in owned input and output buffers, hash tables, retained commands
/// and coding tables; runtime object headers and garbage collection are
/// excluded. `encoder_memory_bound` bounds these buffers and coding scratch
/// before construction (see RESOURCE_BOUNDS.md). `reset` releases input.
/// A dictionary's index is shared by the encoders given it and counted by
/// `Dictionary::memory_usage`, not here.
/// At qualities 5..9 this also counts the read buffer, retained commands,
/// reference hash tables and the ring used after the first window wrap;
/// `encoder_memory_bound` includes their worst case and coding scratch.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.data.length() +
  self.writer.capacity() +
  self.matcher.memory_usage() +
  self.meta_block.memory_usage() +
  4 * self.dist_ring.length() +
  self.ref_memory_usage()
}

///|
/// Compresses from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. Input that was not taken
/// (when the output is full) must be passed again, with the same action.
///
/// `action` applies once all of `input` is taken: `Continue` only takes
/// input, `Flush` compresses everything buffered and pads to a byte
/// boundary, so that the output so far decodes to the input so far, and
/// `Finish` ends the stream. Both stay
/// in effect while the step answers `NeedMoreOutput`. Status: `NeedMoreInput`
/// once everything is taken and its output handed out (a `Flush` is then
/// complete), `NeedMoreOutput` while output waits, `Done` once the stream
/// has ended and been handed out; after that, steps take no input and
/// answer `Done`.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : EncodeAction,
) -> Status {
  self.step_with(input, output, None, action)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Encoder::step_into(
  self : Encoder,
  input : BytesView,
  output : FixedArray[Byte],
  action~ : EncodeAction,
) -> Status {
  self.step_with(input, output.mut_view(), Some(output), action)
}

///|
fn Encoder::step_with(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  action : EncodeAction,
) -> Status {
  if self.quality != 4 {
    return self.ref_step(input, output, fixed_output, action)
  }
  self.step_consumed = 0
  self.step_produced = 0
  if self.done {
    return Done
  }
  if input.length() == 0 {
    self.latch(action)
  }
  let mut consumed = 0
  let mut produced = 0
  for ;; {
    produced = self.drain(output, fixed_output, produced)
    if self.writer.pending() > 0 {
      return self.finish_step(NeedMoreOutput, consumed, produced)
    }
    if self.emitted_final {
      self.done = true
      return self.finish_step(Done, consumed, produced)
    }
    if self.finish_requested {
      self.emit_final()
      continue
    }
    if self.flush_requested {
      self.emit_flush()
      continue
    }
    let buffered = self.data_len - self.block_start
    if buffered == BLOCK_SIZE {
      // A full meta-block is the last only if `Finish` follows it: when this
      // step's input ends here, keep it until the next step says, so that
      // the stream does not depend on where the input was split.
      if consumed == input.length() {
        return self.finish_step(NeedMoreInput, consumed, produced)
      }
      self.write_header()
      self.encode_block(self.block_start, self.data_len, false)
      self.block_start = self.data_len
      continue
    }
    if consumed == input.length() {
      return self.finish_step(NeedMoreInput, consumed, produced)
    }
    let take = (input.length() - consumed).min(BLOCK_SIZE - buffered)
    self.append(input[consumed:consumed + take])
    consumed += take
    if consumed == input.length() {
      self.latch(action)
    }
  }
}

///|
fn Encoder::finish_step(
  self : Encoder,
  status : Status,
  consumed : Int32,
  produced : Int32,
) -> Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Takes `action` once its input is all taken; a finished stream takes no
/// more requests.
fn Encoder::latch(self : Encoder, action : EncodeAction) -> Unit {
  guard !self.finish_requested else { return }
  match action {
    Continue => ()
    Flush => self.flush_requested = true
    Finish => self.finish_requested = true
  }
}

///|
/// Hands out waiting output into `output` from `pos`; the new position.
fn Encoder::drain(
  self : Encoder,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  pos : Int32,
) -> Int32 {
  match fixed_output {
    Some(out) => self.writer.drain_into(out, pos)
    None => self.writer.drain(output, pos)
  }
}

///|
/// Copies `bytes` (at most what fills a meta-block) after the buffered
/// input, growing or sliding the buffer.
fn Encoder::append(self : Encoder, bytes : BytesView) -> Unit {
  let n = bytes.length()
  if self.data_len + n > self.data.length() &&
    self.data.length() < self.data_max {
    let mut size = self.data.length().max(INITIAL_BUFFER)
    while size < self.data_len + n {
      size = size * 2
    }
    let grown = FixedArray::make(size.min(self.data_max), b'\x00')
    FixedArray::unsafe_blit(grown, 0, self.data, 0, self.data_len)
    self.data = grown
  }
  if self.data_len + n > self.data.length() {
    // Keep the window before the input not encoded yet. `data_max` leaves
    // room for at least a meta-block, so the shift is at least that.
    let shift = self.block_start - self.max_distance
    FixedArray::unsafe_blit(
      self.data,
      0,
      self.data,
      shift,
      self.data_len - shift,
    )
    self.data_len -= shift
    self.block_start -= shift
    self.matcher.slide(shift)
  }
  self.data.blit_from_bytesview(self.data_len, bytes)
  self.data_len += n
}

///|
/// The stream header: WBITS (section 9.1), before the first meta-block.
fn Encoder::write_header(self : Encoder) -> Unit {
  guard !self.header_written else { return }
  self.header_written = true
  let w = self.writer
  let wbits = self.window_bits
  if wbits == 16 {
    w.write(1, 0)
  } else if wbits == 17 {
    w.write(7, 1)
  } else if wbits > 17 {
    w.write(4, 1 | ((wbits - 17) << 1))
  } else {
    w.write(7, 1 | ((wbits - 8) << 4))
  }
}

///|
/// Encodes the buffered input and pads to a byte boundary with an empty
/// metadata meta-block, as the reference encoder's flush does.
fn Encoder::emit_flush(self : Encoder) -> Unit {
  self.flush_requested = false
  self.write_header()
  if self.block_start < self.data_len {
    self.encode_block(self.block_start, self.data_len, false)
    self.block_start = self.data_len
  }
  if !self.writer.is_aligned() {
    // ISLAST 0, MNIBBLES 0 (a metadata block), reserved 0, MSKIPBYTES 0.
    self.writer.write(6, 0b000110)
    self.writer.align()
  }
}

///|
/// Encodes the buffered input as the last meta-block and pads the stream.
fn Encoder::emit_final(self : Encoder) -> Unit {
  self.write_header()
  if self.block_start < self.data_len {
    self.encode_block(self.block_start, self.data_len, true)
    self.block_start = self.data_len
  } else {
    // ISLAST and ISLASTEMPTY.
    self.writer.write(2, 3)
  }
  self.writer.align()
  self.emitted_final = true
}
