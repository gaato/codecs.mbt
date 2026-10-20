// Frames and blocks (RFC 8878 sections 3.1 and 3.1.1.2): the units of the
// state machine outside compressed blocks.

///|
/// The magic number that starts every frame, or a skippable one.
fn Decoder::magic(self : Decoder) -> Unit raise Stop {
  self.fill(4)
  let magic = self.hdr_le(0, 4).to_uint()
  if magic == FRAME_MAGIC {
    self.hdr_len = 0
    self.state = FrameHeader
  } else if (magic & 0xFFFFFFF0) == 0x184D2A50 {
    self.state = SkippableSize
  } else if self.frames == 0 {
    raise corrupt("not a zstd stream")
  } else {
    raise Fail(TrailingData, "data after the last frame that starts no frame")
  }
}

///|
fn Decoder::skippable_size(self : Decoder) -> Unit raise Stop {
  self.fill(8)
  self.remaining = self.hdr_le(4, 4).reinterpret_as_int64()
  self.hdr_len = 0
  self.state = SkippableData
}

///|
/// Skips a skippable frame's data without keeping it.
fn Decoder::skippable_data(self : Decoder) -> Unit raise Stop {
  let take = self.remaining.min((self.view.length() - self.in_pos).to_int64())
  self.in_pos += take.to_int()
  self.remaining -= take
  if self.remaining > 0 {
    raise NeedInput
  }
  self.end_member()
}

///|
/// The frame header: what the frame holds and the window it needs.
fn Decoder::frame_header(self : Decoder) -> Unit raise Stop {
  self.fill(1)
  let descriptor = self.hdr[0].to_int()
  let fcs_flag = descriptor >> 6
  let single_segment = (descriptor & 0x20) != 0
  if (descriptor & 0x08) != 0 {
    raise corrupt("the frame header's reserved bit is set")
  }
  let did_size = match descriptor & 3 {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
  let fcs_size = match fcs_flag {
    0 => if single_segment { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
  let window_size = if single_segment { 0 } else { 1 }
  self.fill(1 + window_size + did_size + fcs_size)
  let mut at = 1
  // Computed in 64 bits: a descriptor may ask for up to 2^41 + 7 * 2^38.
  let mut window : UInt64 = 0
  if !single_segment {
    let b = self.hdr[at].to_int()
    let base = 1UL << (10 + (b >> 3))
    window = base + (base >> 3) * (b & 7).to_uint64()
    at += 1
  }
  if did_size > 0 && self.hdr_le(at, did_size) != 0 {
    let id = self.hdr_le(at, did_size).to_uint()
    raise Fail(DictionaryRequired(Some(id)), "the frame needs dictionary \{id}")
  }
  at += did_size
  self.content_size = if fcs_size > 0 {
    let size = self.hdr_le(at, fcs_size)
    Some(if fcs_size == 2 { size + 256 } else { size })
  } else {
    None
  }
  if single_segment {
    window = self.content_size.unwrap_or(0)
  }
  let limit = 1UL << self.max_window_bits
  if window > limit {
    raise Fail(
      LimitExceeded({ resource: Memory, needed: Some(window), limit, }),
      "the frame needs a \{window}-byte window, over the \{limit}-byte limit",
    )
  }
  self.window = window.to_int()
  self.block_max = self.window.min(MAX_BLOCK_SIZE)
  self.has_checksum = (descriptor & 0x04) != 0
  self.frame_out = 0
  self.xxh.reset()
  self.huffman_valid = false
  self.ll_table = None
  self.of_table = None
  self.ml_table = None
  self.rep[0] = 1
  self.rep[1] = 4
  self.rep[2] = 8
  self.new_frame = true
  self.hdr_len = 0
  self.state = BlockHeader
}

///|
/// Sets the window up for a new frame once the last frame's output is all
/// handed out; false until then.
fn Decoder::start_window(self : Decoder) -> Bool {
  if self.pending > 0 {
    self.drain()
    if self.pending > 0 {
      return false
    }
  }
  if self.ring.length() > self.window {
    self.ring = FixedArray::make(0, b'\x00')
  }
  self.ring_max = self.window
  self.wpos = 0
  self.filled = 0
  self.new_frame = false
  true
}

///|
fn Decoder::block_header(self : Decoder) -> Status? raise Stop {
  if self.new_frame && !self.start_window() {
    return Some(NeedMoreOutput)
  }
  self.fill(3)
  let header = self.hdr_le(0, 3).to_int()
  self.hdr_len = 0
  self.last_block = (header & 1) != 0
  let size = header >> 3
  self.block_size = size
  self.block_out = 0
  match (header >> 1) & 3 {
    0 => {
      if size > self.block_max {
        raise corrupt("a raw block larger than the block limit")
      }
      self.remaining = size.to_int64()
      self.state = RawBlock
    }
    1 => {
      if size > self.block_max {
        raise corrupt("an RLE block larger than the block limit")
      }
      self.state = RleByte
    }
    2 => {
      if size > self.block_max {
        raise corrupt("a compressed block larger than the block limit")
      }
      if size == 0 {
        raise corrupt("an empty compressed block")
      }
      if self.block.length() < size {
        self.block = FixedArray::make(size, b'\x00')
      }
      self.block_len = 0
      self.state = CompressedBlock
    }
    _ => raise corrupt("a block of the reserved type")
  }
  None
}

///|
fn Decoder::raw_block(self : Decoder) -> Status? raise Stop {
  while self.remaining > 0 {
    let available = self.view.length() - self.in_pos
    if available == 0 {
      raise NeedInput
    }
    let n = self.room(self.remaining.to_int().min(available))
    if n == 0 {
      return Some(NeedMoreOutput)
    }
    self.copy_input(n)
    self.remaining -= n.to_int64()
  }
  self.end_block()
  None
}

///|
fn Decoder::rle_byte(self : Decoder) -> Unit raise Stop {
  self.fill(1)
  self.rle_byte = self.hdr[0]
  self.hdr_len = 0
  self.remaining = self.block_size.to_int64()
  self.state = RleRun
}

///|
fn Decoder::rle_run(self : Decoder) -> Status? raise Stop {
  while self.remaining > 0 {
    let n = self.room(self.remaining.to_int())
    if n == 0 {
      return Some(NeedMoreOutput)
    }
    self.put_run(self.rle_byte, n)
    self.remaining -= n.to_int64()
  }
  self.end_block()
  None
}

///|
/// Gathers a compressed block, then decodes it once earlier output is all
/// handed out.
fn Decoder::compressed_block(self : Decoder) -> Status? raise Stop {
  let take = (self.block_size - self.block_len).min(
    self.view.length() - self.in_pos,
  )
  if take > 0 {
    self.block.blit_from_bytesview(
      self.block_len,
      self.view[self.in_pos:self.in_pos + take],
    )
    self.block_len += take
    self.in_pos += take
  }
  if self.block_len < self.block_size {
    raise NeedInput
  }
  if self.pending > 0 {
    self.drain()
    if self.pending > 0 {
      return Some(NeedMoreOutput)
    }
  }
  self.decode_block()
  self.end_block()
  None
}

///|
fn Decoder::end_block(self : Decoder) -> Unit raise Stop {
  if self.content_size is Some(size) && self.frame_out > size {
    raise corrupt("the frame holds more than its declared content size")
  }
  if !self.last_block {
    self.state = BlockHeader
  } else if self.has_checksum {
    self.state = Checksum
  } else {
    self.end_frame()
  }
}

///|
fn Decoder::checksum(self : Decoder) -> Unit raise Stop {
  self.fill(4)
  let stored = self.hdr_le(0, 4).to_uint()
  self.hdr_len = 0
  if stored != self.xxh.digest().to_uint() {
    raise Fail(ChecksumMismatch, "the frame's content checksum does not match")
  }
  self.end_frame()
}

///|
fn Decoder::end_frame(self : Decoder) -> Unit raise Stop {
  if self.content_size is Some(size) && self.frame_out != size {
    raise corrupt("the frame holds less than its declared content size")
  }
  self.end_member()
}

///|
/// Counts a whole frame, skippable or not. Under `EndOfMember` the stream
/// ends here; otherwise another frame may follow.
fn Decoder::end_member(self : Decoder) -> Unit {
  self.frames += 1
  self.state = if self.until is EndOfMember { Done } else { Magic }
}
