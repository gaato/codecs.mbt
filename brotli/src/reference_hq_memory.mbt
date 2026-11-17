// Optional allocation accounting for the HQ phases. Counts backing extents,
// not runtime headers or garbage awaiting collection, as RESOURCE_BOUNDS.md.
// The observer belongs to H10, so qualities 4..9 have no extra state or work.

///|
// Constructed and inspected by white-box tests and the measurement script;
// ordinary encodes never enable this observer.
#warnings("-struct_never_constructed-unused_field")
priv struct HqPeak {
  mut bytes : Int64
  mut parser : Int64
  mut archive_capacity : Int32
  mut archive_grows : Int32
  mut passes : Int32
  mut second_model : Int64
  mut blocks : Int32
  mut clusters : Int32
  mut trees_upper : Int64
}

///|
priv struct HqMemory {
  owner : Encoder
  peak : HqPeak
  parsing : Bool
  mut live : Int64
}

///|
fn HqMemory::new(owner : Encoder, peak : HqPeak, parsing : Bool) -> HqMemory {
  { owner, peak, parsing, live: 0L, }
}

///|
fn hq_memory_mark(memory : HqMemory?) -> Int64 {
  match memory {
    Some(m) => m.live
    None => 0L
  }
}

///|
fn hq_memory_add(memory : HqMemory?, bytes : Int64) -> Unit {
  if memory is Some(m) {
    m.live += bytes
    m.peak.bytes = m.peak.bytes.max(m.owner.memory_usage().to_int64() + m.live)
    if m.parsing {
      m.peak.parser = m.peak.parser.max(m.live)
    }
  }
}

///|
fn hq_memory_restore(memory : HqMemory?, mark : Int64) -> Unit {
  // Include retained buffers grown by backtracking or bit emission before
  // dropping this scope's scratch. No collected/dead backing is accumulated.
  hq_memory_add(memory, 0L)
  if memory is Some(m) {
    m.live = mark
  }
}

///|
fn HqDp::memory_usage(self : HqDp) -> Int64 {
  4L *
  (self.lengths.length() +
  self.distances.length() +
  self.inserts.length() +
  self.info.length() +
  self.model.commands.length() +
  self.model.distances.length() +
  self.model.literals.length() +
  self.model.histogram.length() +
  self.positions.length() +
  self.cache.length() +
  self.costs.length() +
  self.differences.length()).to_int64()
}

///|
#cfg(any(target="native", target="wasm"))
const HQ_REUSES_BUFFERS : Bool = true

///|
#cfg(not(any(target="native", target="wasm")))
const HQ_REUSES_BUFFERS : Bool = false

///|
fn hq_memory_handoff(
  memory : HqMemory?,
  capacity : Int32,
  length : Int32,
) -> Unit {
  // These local arrays have no surviving aliases. FixedArray::from_array
  // consumes the last view and reuses a full buffer on native/linear Wasm.
  // Otherwise include the copy overlap, then release the consumed source.
  if !HQ_REUSES_BUFFERS || capacity != length {
    hq_memory_add(memory, 4L * length.to_int64())
    hq_memory_add(memory, -4L * capacity.to_int64())
  }
}

///|
fn HqHistogram::memory_usage(self : HqHistogram) -> Int64 {
  // One backing pointer, total, cost and alignment; array slots are separate.
  4L * self.data.length().to_int64() + 24L
}

///|
fn hq_histograms_memory(hist : Array[HqHistogram]) -> Int64 {
  hist.fold(init=0L, (n, h) => n + h.memory_usage()) +
  8L * hist.capacity().to_int64()
}

///|
fn RefSplit::hq_memory_usage(self : RefSplit) -> Int64 {
  4L *
  (self.types.capacity() + self.lengths.capacity() + self.current.length()).to_int64() +
  8L *
  (self.hist.capacity() +
  self.last_entropy.length() +
  self.second_entropy.length()).to_int64() +
  self.hist.fold(init=0L, (n, h) => n + 4L * h.length().to_int64())
}
