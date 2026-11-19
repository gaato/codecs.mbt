// Port of google/brotli v1.2.1 c/enc/encode.c.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
fn Encoder::hq_process(self : Encoder, is_last : Bool, flush : Bool) -> Unit {
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
  let tree = match self.hq_tree() {
    Some(h) => h
    None => {
      let h = HqTree::new(
        self.window_bits,
        length,
        self.ref_offset + start.to_int64() == 0L && is_last,
      )
      self.arena = Some(Hq(h))
      h
    }
  }
  tree.stitch(
    self.data,
    start,
    ref_wrap(self.ref_offset + start.to_int64()),
    length,
  )
  if !commands.is_empty() && self.ref_insert == 0 {
    let last = commands[commands.length() - 1]
    let distance = self.ref_distances[0]
    let reach_at_copy = (self.ref_offset +
    start.to_int64() -
    last.copy.to_int64()).min(self.max_distance.to_int64())
    if (last.raw_distance < 16 || last.raw_distance - 15 == distance) &&
      distance.to_int64() <= reach_at_copy {
      // The retained window covers distance and end is the valid data end.
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
    self.hq_parse(
      tree,
      self.quality,
      start,
      end,
      ref_wrap(self.ref_offset + start.to_int64()),
    )
  }
  if ref_wrap(self.ref_offset + end.to_int64()) <
    ref_wrap(self.ref_offset + self.ref_processed.to_int64()) {
    tree.prepared = false
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
