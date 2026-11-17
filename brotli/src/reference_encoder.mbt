// Port of google/brotli v1.2.1 c/enc/encode.c and backward_references_inc.h.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
fn ref_input_block(quality : Int32, window : Int32) -> Int32 {
  if quality <= 1 {
    return 1 << window
  }
  if quality <= 3 {
    return 16384
  }
  1 << (if quality >= 9 && window > 16 { window.min(18) } else { 16 })
}

///|
fn ref_max_meta(quality : Int32, window : Int32) -> Int32 {
  if quality <= 3 {
    return 1 << (window.max(14) + 1).min(24)
  }
  let block_bits = if quality >= 9 && window > 16 { window.min(18) } else { 16 }
  1 << (window.max(block_bits) + 1).min(24)
}

///|
fn ref_wrap(pos : Int64) -> UInt32 {
  let gb = pos >> 30
  if gb > 2L {
    ((pos & 1073741823L) | ((((gb - 1L) & 1L) + 1L) << 30))
    .to_int()
    .reinterpret_as_uint()
  } else {
    pos.to_int().reinterpret_as_uint()
  }
}

///|
fn Encoder::ref_memory_usage(self : Encoder) -> Int32 {
  self.ref_batch.length() +
  self.ref_ring.length() +
  4 * (self.ref_distances.length() + self.ref_saved_distances.length()) +
  (match self.ref_commands {
    Some(commands) => 40 * commands.capacity()
    None => 0
  }) +
  (match self.ref_hasher {
    Some(h) => h.memory_usage()
    None => 0
  }) +
  self.low_memory() +
  (match self.hq_tree() {
    Some(h) => h.memory_usage()
    None => 0
  })
}

///|
fn Encoder::ref_append(self : Encoder, start : Int32, n : Int32) -> Unit {
  if self.data_len + n + 8 > self.data.length() &&
    self.data.length() < self.data_max {
    let mut size = self.data.length().max(INITIAL_BUFFER)
    while size < self.data_len + n + 8 {
      size *= 2
    }
    let data = FixedArray::make(size.min(self.data_max), b'\x00')
    FixedArray::unsafe_blit(data, 0, self.data, 0, self.data_len)
    self.data = data
  }
  if self.data_len + n + 8 > self.data.length() {
    let shift = (self.ref_processed - self.max_distance).min(
      self.block_start - 2,
    )
    FixedArray::unsafe_blit(
      self.data,
      0,
      self.data,
      shift,
      self.data_len - shift,
    )
    self.data_len -= shift
    self.ref_processed -= shift
    self.block_start -= shift
    self.ref_offset += shift.to_int64()
  }
  FixedArray::unsafe_blit(self.data, self.data_len, self.ref_batch, start, n)
  self.data_len += n
  let ring_size = 1 <<
    (
      self.window_bits.max(
        if self.quality >= 9 {
          self.window_bits.min(18).max(16)
        } else if self.quality <= 3 {
          14
        } else {
          16
        },
      ) +
      1
    )
  let absolute_end = self.ref_offset + self.data_len.to_int64()
  let end_index = (absolute_end & (ring_size - 1).to_int64()).to_int()
  if absolute_end >= ring_size.to_int64() {
    if self.ref_ring.is_empty() {
      self.ref_ring = FixedArray::make(ring_size, b'\x00')
      FixedArray::unsafe_blit(
        self.ref_ring,
        end_index,
        self.data,
        self.data_len - ring_size,
        ring_size - end_index,
      )
      FixedArray::unsafe_blit(
        self.ref_ring,
        0,
        self.data,
        self.data_len - end_index,
        end_index,
      )
    } else {
      let begin = (end_index - n + ring_size) & (ring_size - 1)
      let first = n.min(ring_size - begin)
      FixedArray::unsafe_blit(
        self.ref_ring,
        begin,
        self.ref_batch,
        start,
        first,
      )
      FixedArray::unsafe_blit(
        self.ref_ring,
        0,
        self.ref_batch,
        start + first,
        n - first,
      )
    }
    for i in 0..<8 {
      self.data[self.data_len + i] = self.ref_ring[(end_index + i) &
        (ring_size - 1)]
    }
  } else {
    self.data.fill(b'\x00', start=self.data_len, end=self.data_len + 8)
  }
}

///|
fn ref_distance_code(
  distance : Int32,
  reach : Int32,
  cache : FixedArray[Int32],
) -> Int32 {
  if distance <= reach {
    if distance == cache[0] {
      return 0
    }
    if distance == cache[1] {
      return 1
    }
    let o0 = distance + 3 - cache[0]
    let o1 = distance + 3 - cache[1]
    if o0 >= 0 && o0 < 7 {
      return (0x9750468 >> (4 * o0)) & 15
    }
    if o1 >= 0 && o1 < 7 {
      return (0xfdb1ace >> (4 * o1)) & 15
    }
    if distance == cache[2] {
      return 2
    }
    if distance == cache[3] {
      return 3
    }
  }
  distance + 15
}

///|
fn Encoder::ref_find(
  self : Encoder,
  hasher : RefHasher,
  pos : Int32,
  end : Int32,
) -> RefMatch {
  let total = self.ref_offset + pos.to_int64()
  let reach = total.min(self.max_distance.to_int64()).to_int()
  let dictionary_reach = self.ref_dictionary_reach(reach)
  let result = hasher.find(
    self.data,
    pos,
    ref_wrap(total),
    end,
    reach,
    dictionary_reach,
    self.ref_distances,
  )
  if self.dictionary is Some(dict) && end - pos >= 4 {
    let index = dict.search_index()
    let n = index.bytes.length()
    let mut q = index.head[@lz77.hash4(self.data, pos, index.bits)] - 1
    let mut attempts = DICTIONARY_ATTEMPTS
    while q >= 0 && attempts > 0 {
      let distance = reach + n - q
      if distance > MAX_CODED_DISTANCE {
        break
      }
      let limit = (end - pos).min(n - q)
      let mut length = 0
      while length < limit && index.bytes[q + length] == self.data[pos + length] {
        length += 1
      }
      if length >= 4 {
        let score = ref_score(length, distance)
        if score > result.score {
          result.length = length
          result.distance = distance
          result.score = score
          result.delta = 0
        }
      }
      q = index.chain[q] - 1
      attempts -= 1
    }
  }
  result
}

///|
fn Encoder::ref_parse(
  self : Encoder,
  hasher : RefHasher,
  start : Int32,
  end : Int32,
) -> Unit {
  let commands = self.ref_commands.unwrap()
  let lookahead = if hasher.long_hash { 8 } else { 4 }
  let store_end = if end - start >= lookahead {
    end - lookahead + 1
  } else {
    start
  }
  let spree = if self.quality < 9 { 64 } else { 512 }
  let mut random_at = start + spree
  let mut pos = start
  let mut insert = self.ref_insert
  let cache = self.ref_distances
  ref_prepare_distances(cache)
  while pos + lookahead < end {
    let mut found = self.ref_find(hasher, pos, end)
    if found.score > 2020 {
      let mut delayed = 0
      for ;; {
        let next = self.ref_find(hasher, pos + 1, end)
        if next.score >= found.score + 175 {
          pos += 1
          insert += 1
          found = next
          delayed += 1
          if delayed < 4 && pos + lookahead < end {
            continue
          }
        }
        break
      }
      random_at = pos + 2 * found.length + spree
      let total = self.ref_offset + pos.to_int64()
      let reach = total.min(self.max_distance.to_int64()).to_int()
      let dictionary_reach = self.ref_dictionary_reach(reach)
      let dc = ref_distance_code(found.distance, dictionary_reach, cache)
      if found.distance <= dictionary_reach && dc > 0 {
        cache[3] = cache[2]
        cache[2] = cache[1]
        cache[1] = cache[0]
        cache[0] = found.distance
        ref_prepare_distances(cache)
      }
      commands.push(RefCommand::new(insert, found.length, found.delta, dc))
      self.ref_literals += insert
      insert = 0
      let range_end = (pos + found.length).min(store_end)
      let mut range_start = pos + 2
      if found.distance < found.length >> 2 {
        range_start = range_end.min(
          range_start.max(pos + found.length - (found.distance << 2)),
        )
      }
      for p in range_start..<range_end {
        hasher.store(self.data, p, ref_wrap(self.ref_offset + p.to_int64()))
      }
      pos += found.length
    } else {
      insert += 1
      pos += 1
      if pos > random_at {
        let step = if pos > random_at + 4 * spree { 4 } else { 2 }
        let jump = (pos + 4 * step).min(end - (lookahead - 1).max(step))
        while pos < jump {
          hasher.store(
            self.data,
            pos,
            ref_wrap(self.ref_offset + pos.to_int64()),
          )
          pos += step
          insert += step
        }
      }
    }
  }
  self.ref_insert = insert + end - pos
}

///|
fn Encoder::ref_dictionary_reach(self : Encoder, reach : Int32) -> Int32 {
  let gap = match self.dictionary {
    Some(d) => d.length()
    None => 0
  }
  // Past the distance alphabet, static words cannot be addressed. Saturate
  // before adding a caller-sized dictionary to avoid 32-bit overflow.
  (reach.to_int64() + gap.to_int64())
  .min(MAX_CODED_DISTANCE.to_int64() + 1L)
  .to_int()
}

///|
fn Encoder::ref_process(self : Encoder, is_last : Bool, flush : Bool) -> Unit {
  if self.quality <= 1 {
    self.fragment_process(is_last)
    return
  }
  if self.quality <= 3 {
    self.quick_process(is_last, flush)
    return
  }
  if self.quality >= 10 {
    self.hq_process(is_last, flush)
    return
  }
  let commands = self.ref_commands.unwrap()
  let mut start = self.ref_processed
  let end = self.data_len
  let length = end - start
  if length == 0 && !is_last && !flush {
    return
  }
  if self.ref_hint == 0L {
    self.ref_hint = self.ref_batch_len.to_int64()
  }
  let hasher = match self.ref_hasher {
    Some(h) => h
    None => {
      let h = RefHasher::new(self.quality, self.window_bits, self.ref_hint)
      self.ref_hasher = Some(h)
      h
    }
  }
  hasher.prepare()
  let lookahead = if hasher.long_hash { 8 } else { 4 }
  if length >= lookahead - 1 && self.ref_offset + start.to_int64() >= 3L {
    for p in (start - 3)..<start {
      hasher.store(self.data, p, ref_wrap(self.ref_offset + p.to_int64()))
    }
  }
  if !commands.is_empty() && self.ref_insert == 0 {
    let last = commands[commands.length() - 1]
    let distance = self.ref_distances[0]
    let reach_at_copy = (self.ref_offset +
    start.to_int64() -
    last.copy.to_int64()).min(self.max_distance.to_int64())
    if (last.raw_distance < 16 || last.raw_distance - 15 == distance) &&
      distance.to_int64() <= reach_at_copy {
      let more = ref_match_length(
        self.data,
        start - distance,
        start,
        end - start,
      )
      last.copy += more
      last.copy_code += more
      last.symbol = command_symbol(
        insert_code(last.insert),
        copy_code(last.copy_code),
        last.distance == 0,
      )
      start += more
    }
  }
  if start < end {
    self.ref_parse(hasher, start, end)
  }
  if ref_wrap(self.ref_offset + end.to_int64()) <
    ref_wrap(self.ref_offset + self.ref_processed.to_int64()) {
    hasher.reset()
  }
  self.ref_processed = end
  let max_meta = ref_max_meta(self.quality, self.window_bits)
  if !is_last &&
    !flush &&
    end - self.block_start + ref_input_block(self.quality, self.window_bits) <=
    max_meta &&
    self.ref_literals < max_meta / 8 &&
    commands.length() < max_meta / 8 {
    return
  }
  if self.ref_insert > 0 {
    commands.push(RefCommand::new(self.ref_insert, 0, 4, 16))
    self.ref_literals += self.ref_insert
    self.ref_insert = 0
  }
  self.write_header()
  self.ref_emit(is_last)
  self.block_start = end
  commands.clear()
  self.ref_literals = 0
  for i in 0..<4 {
    self.ref_saved_distances[i] = self.ref_distances[i]
  }
}

///|
fn Encoder::ref_emit(self : Encoder, is_last : Bool) -> Unit {
  let commands = self.ref_commands.unwrap()
  let n = self.data_len - self.block_start
  let w = self.writer
  if n == 0 {
    if is_last {
      w.write(2, 3)
      w.align()
    }
    return
  }
  let mark = w.mark()
  let mut compress = n > 2
  if commands.length() < (n >> 8) + 2 &&
    self.ref_literals.to_double() > 0.99 * n.to_double() {
    let hist = FixedArray::make(256, 0)
    for p = self.block_start; p < self.data_len; p = p + 13 {
      hist[self.data[p].to_int()] += 1
    }
    if ref_entropy(hist) > n.to_double() * 7.92 * (1.0 / 13.0) {
      compress = false
    }
  }
  if compress {
    let before = w.position()
    if self.quality >= 10 {
      hq_store_block(
        w,
        self.data,
        self.block_start,
        self.data_len,
        commands,
        self.quality,
        is_last,
        memory?=self.hq_tree().unwrap().peak.map(p => {
          HqMemory::new(self, p, false)
        }),
      )
    } else if self.quality <= 3 {
      self.low_store(is_last)
    } else {
      ref_store_block(
        w,
        self.data,
        self.block_start,
        self.data_len,
        commands,
        self.quality,
        self.ref_hint,
        is_last,
      )
    }
    if n + 4 >= (w.position() - (before & -8)) >> 3 {
      return
    }
    w.rewind(mark)
  }
  for i in 0..<4 {
    self.ref_distances[i] = self.ref_saved_distances[i]
  }
  w.write(1, 0)
  ref_length(w, n)
  w.write(1, 1)
  w.align()
  w.write_bytes(self.data, self.block_start, n)
  if is_last {
    w.write(2, 3)
    w.align()
  }
}

///|
fn Encoder::ref_step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  action : EncodeAction,
) -> Status {
  self.step_consumed = 0
  self.step_produced = 0
  if self.done {
    return Done
  }
  let mut consumed = 0
  let mut produced = 0
  if input.is_empty() {
    self.latch(action)
  }
  for ;; {
    produced = self.drain(output, fixed_output, produced)
    if self.writer.pending() > 0 {
      return self.finish_step(NeedMoreOutput, consumed, produced)
    }
    if self.emitted_final {
      self.done = true
      return self.finish_step(Done, consumed, produced)
    }
    let ready = self.ref_batch_len == 524288 ||
      self.flush_requested ||
      self.finish_requested
    if ready && self.ref_batch_pos < self.ref_batch_len {
      let count = (self.ref_batch_len - self.ref_batch_pos).min(
        ref_input_block(self.quality, self.window_bits),
      )
      if self.quality <= 1 {
        self.fragment_append(self.ref_batch_pos, count)
      } else {
        self.ref_append(self.ref_batch_pos, count)
      }
      self.ref_batch_pos += count
      let last_batch = self.ref_batch_len < 524288 &&
        self.ref_batch_pos == self.ref_batch_len
      self.ref_process(
        last_batch && self.finish_requested,
        last_batch && self.flush_requested,
      )
      if last_batch && self.finish_requested {
        self.emitted_final = true
      }
      continue
    }
    if ready {
      self.ref_batch_len = 0
      self.ref_batch_pos = 0
      if self.finish_requested {
        self.ref_process(true, false)
        self.emitted_final = true
        continue
      }
      if self.flush_requested {
        self.ref_process(false, true)
        self.flush_requested = false
        self.write_header()
        if !self.writer.is_aligned() {
          self.writer.write(6, 6)
          self.writer.align()
        }
        continue
      }
    }
    if consumed == input.length() {
      return self.finish_step(NeedMoreInput, consumed, produced)
    }
    if self.ref_batch.is_empty() {
      self.ref_batch = FixedArray::make(524288, b'\x00')
    }
    let take = (input.length() - consumed).min(524288 - self.ref_batch_len)
    self.ref_batch.blit_from_bytesview(
      self.ref_batch_len,
      input[consumed:consumed + take],
    )
    consumed += take
    self.ref_batch_len += take
    if consumed == input.length() {
      self.latch(action)
    }
  }
}
