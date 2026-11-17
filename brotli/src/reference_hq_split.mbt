// Port of google/brotli v1.2.1 c/enc/block_splitter{,_inc.h}.c.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
fn hq_split_blocks(
  data : FixedArray[Int32],
  ids : FixedArray[Int32],
  blocks : Int32,
  alphabet : Int32,
  memory? : HqMemory,
) -> RefSplit {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let lengths = FixedArray::make(blocks, 0)
  let mut block = 0
  for i in 0..<data.length() {
    lengths[block] += 1
    if i + 1 == data.length() || ids[i] != ids[i + 1] {
      block += 1
    }
  }
  let all : Array[HqHistogram] = []
  let sizes_all : Array[Int32] = []
  let symbols = FixedArray::make(blocks, 0)
  let tmp = HqHistogram::new(alphabet)
  hq_memory_add(
    memory,
    4L * (lengths.length() + symbols.length()).to_int64() + tmp.memory_usage(),
  )
  if memory is Some(m) {
    m.peak.blocks = m.peak.blocks.max(blocks)
  }
  let mut pos = 0
  for first = 0; first < blocks; first = first + 64 {
    let count = (blocks - first).min(64)
    let hist = Array::makei(count, _ => HqHistogram::new(alphabet))
    let sizes = FixedArray::make(count, 1)
    let assignment = FixedArray::makei(count, i => i)
    let clusters = Array::makei(count, i => i)
    let batch_mark = hq_memory_mark(memory)
    hq_memory_add(
      memory,
      hq_histograms_memory(hist) +
      4L *
      (sizes.length() + assignment.length() + clusters.capacity()).to_int64(),
    )
    for j in 0..<count {
      for _ in 0..<lengths[first + j] {
        hist[j].add(data[pos])
        pos += 1
      }
      hist[j].cost = hist[j].population(memory?)
    }
    hq_combine(
      hist,
      tmp,
      sizes,
      assignment.mut_view(),
      clusters,
      64,
      2048,
      memory?,
    )
    let remap = FixedArray::make(count, 0)
    hq_memory_add(memory, 4L * remap.length().to_int64())
    let offset = all.length()
    let old_all = all.capacity()
    let old_sizes = sizes_all.capacity()
    for j, c in clusters {
      remap[c] = j
      all.push(hist[c])
      sizes_all.push(sizes[c])
    }
    for j in 0..<count {
      symbols[first + j] = offset + remap[assignment[j]]
    }
    let slots = 8L * (all.capacity() - old_all).to_int64() +
      4L * (sizes_all.capacity() - old_sizes).to_int64()
    hq_memory_add(memory, slots)
    hq_memory_restore(memory, batch_mark)
    hq_memory_add(
      memory,
      slots + clusters.fold(init=0L, (n, c) => n + hist[c].memory_usage()),
    )
  }
  let sizes_capacity = sizes_all.capacity()
  let sizes = FixedArray::from_array(sizes_all)
  hq_memory_handoff(memory, sizes_capacity, sizes.length())
  let clusters = Array::makei(all.length(), i => i)
  hq_memory_add(memory, 4L * clusters.capacity().to_int64())
  if memory is Some(m) {
    m.peak.clusters = m.peak.clusters.max(all.length())
  }
  hq_combine(
    all,
    tmp,
    sizes,
    symbols.mut_view(),
    clusters,
    256,
    hq_max_pairs(all.length()),
    memory?,
  )
  let index = FixedArray::make(all.length(), -1)
  let mut next = 0
  pos = 0
  let other = HqHistogram::new(alphabet)
  hq_memory_add(memory, 4L * index.length().to_int64() + other.memory_usage())
  for i in 0..<blocks {
    tmp.clear()
    for _ in 0..<lengths[i] {
      tmp.add(data[pos])
      pos += 1
    }
    let mut best = if i == 0 { symbols[0] } else { symbols[i - 1] }
    let mut cost = hq_hist_distance(tmp, all[best], other, memory?)
    for c in clusters {
      let value = hq_hist_distance(tmp, all[c], other, memory?)
      if value < cost {
        cost = value
        best = c
      }
    }
    symbols[i] = best
    if index[best] < 0 {
      index[best] = next
      next += 1
    }
  }
  let split = RefSplit::new(alphabet, 1, 0, 0.0)
  let mut length = 0
  for i in 0..<blocks {
    length += lengths[i]
    if i + 1 == blocks || symbols[i] != symbols[i + 1] {
      split.types.push(index[symbols[i]])
      split.lengths.push(length)
      length = 0
    }
  }
  for _ in 0..<next {
    split.hist.push(FixedArray::make(alphabet, 0))
  }
  hq_memory_add(memory, split.hq_memory_usage())
  split
}

///|
fn hq_split(
  data : FixedArray[Int32],
  alphabet : Int32,
  quality : Int32,
  per_hist : Int32,
  max_hist : Int32,
  stride : Int32,
  switch_cost : Double,
  memory? : HqMemory,
) -> RefSplit {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let length = data.length()
  if length < 128 {
    let split = RefSplit::new(alphabet, 1, 0, 0.0)
    split.types.push(0)
    split.lengths.push(length)
    split.hist.push(FixedArray::make(alphabet, 0))
    hq_memory_add(memory, split.hq_memory_usage())
    return split
  }
  let mut count = (length / per_hist + 1).min(max_hist)
  let hist = Array::makei(count, _ => HqHistogram::new(alphabet))
  hq_memory_add(memory, hq_histograms_memory(hist))
  let block_length = length / count
  let mut seed = 7U
  for i in 0..<count {
    let mut pos = length * i / count
    if i != 0 {
      seed *= 16807U
      pos += (seed % block_length.reinterpret_as_uint()).reinterpret_as_int()
    }
    if pos + stride >= length {
      pos = length - stride - 1
    }
    for j in pos..<(pos + stride) {
      hist[i].add(data[j])
    }
  }
  seed = 7U
  let iters = (2 * length / stride + 100 + count - 1) / count * count
  for iter in 0..<iters {
    seed *= 16807U
    let pos = (seed % (length - stride + 1).reinterpret_as_uint()).reinterpret_as_int()
    for j in pos..<(pos + stride) {
      hist[iter % count].add(data[j])
    }
  }
  let ids = FixedArray::make(length, 0)
  let insert = FixedArray::make(alphabet * count, 0.0)
  let cost = FixedArray::make(count, 0.0)
  let signals = FixedArray::make(length * ((count + 7) >> 3), b'\x00')
  let new_id = FixedArray::make(count, -1)
  hq_memory_add(
    memory,
    4L * (ids.length() + new_id.length()).to_int64() +
    8L * (insert.length() + cost.length()).to_int64() +
    signals.length().to_int64(),
  )
  let mut blocks = 1
  for _ in 0..<(if quality < 11 { 3 } else { 10 }) {
    blocks = 1
    if count > 1 {
      for i in 0..<alphabet {
        for j in 0..<count {
          insert[i * count + j] = ref_log(hist[j].total) -
            (if hist[j].data[i] == 0 { -2.0 } else { ref_log(hist[j].data[i]) })
        }
      }
      cost.fill(0.0)
      signals.fill(b'\x00')
      let bitmap = (count + 7) >> 3
      for at in 0..<length {
        let mut minimum = 1.0e99
        for k in 0..<count {
          cost[k] += insert[data[at] * count + k]
          if cost[k] < minimum {
            minimum = cost[k]
            ids[at] = k
          }
        }
        let switch = if at < 2000 {
          switch_cost * (0.77 + 0.07 / 2000.0 * at.to_double())
        } else {
          switch_cost
        }
        for k in 0..<count {
          cost[k] -= minimum
          if cost[k] >= switch {
            cost[k] = switch
            let ix = at * bitmap + (k >> 3)
            signals[ix] = (signals[ix].to_int() | (1 << (k & 7))).to_byte()
          }
        }
      }
      let mut current = ids[length - 1]
      for at = length - 2; at >= 0; at = at - 1 {
        if (
            signals[at * bitmap + (current >> 3)].to_int() &
            (1 << (current & 7))
          ) !=
          0 &&
          current != ids[at] {
          current = ids[at]
          blocks += 1
        }
        ids[at] = current
      }
    } else {
      ids.fill(0)
    }
    new_id.fill(-1)
    let mut next = 0
    for id in ids {
      if new_id[id] < 0 {
        new_id[id] = next
        next += 1
      }
    }
    for i in 0..<length {
      ids[i] = new_id[ids[i]]
    }
    count = next
    for i in 0..<count {
      hist[i].clear()
    }
    for i in 0..<length {
      hist[ids[i]].add(data[i])
    }
  }
  // Refinement arrays are dead before clustering; ids is the shared result.
  hq_memory_restore(memory, mark)
  hq_memory_add(memory, 4L * ids.length().to_int64())
  hq_split_blocks(data, ids, blocks, alphabet, memory?)
}
