///|
/// The splits every codec is run under: whole, a byte at a time each way,
/// small primes, a big input with a tiny output and the reverse, and random
/// sizes from fixed seeds.
pub fn splits() -> Array[(Sizes, Sizes)] {
  [
    (Sizes::fixed(1), Sizes::fixed(1 << 16)),
    (Sizes::fixed(1 << 20), Sizes::fixed(1)),
    (Sizes::fixed(3), Sizes::fixed(7)),
    (Sizes::fixed(7), Sizes::fixed(3)),
    (Sizes::fixed(64), Sizes::fixed(4096)),
    (Sizes::random(1, 17), Sizes::random(2, 5000)),
    (Sizes::random(3, 1500), Sizes::random(4, 3)),
  ]
}

///|
/// Runs a fresh codec over `input` whole, then under every split of
/// `splits()`, and fails unless every run agrees with the whole one. Returns
/// the whole run. Byte-at-a-time splits are skipped for inputs whose output
/// passes `small` bytes, to keep run time down.
pub fn[S : Stepper] check_splits(
  make : () -> S,
  input : BytesView,
  memory_limit~ : Int32? = None,
  small~ : Int32 = 1 << 16,
) -> Transcript raise {
  let whole = drive(make(), input, memory_limit~)
  for split in splits() {
    let (input_sizes, output_sizes) = split
    let tiny = input_sizes.label == "1" || output_sizes.label == "1"
    if tiny && whole.output.length() > small {
      continue
    }
    let run = drive(make(), input, input_sizes~, output_sizes~, memory_limit~)
    if !run.agrees(whole) {
      fail(
        "input in \{input_sizes.label}, output in \{output_sizes.label}: " +
        "\{describe(run)}, whole: \{describe(whole)}",
      )
    }
  }
  whole
}

///|
fn describe(run : Transcript) -> String {
  let error = match run.error {
    Some(kind) => @debug.to_string(kind)
    None => "no error"
  }
  "\{run.output.length()} bytes, \{run.events.length()} events, \{error}"
}

///|
/// Checks that every proper prefix of a valid `input` (all of them up to
/// `max_prefixes`, then an even spread) either raises `Truncated`, or ends
/// cleanly where a whole member ends, with output that begins the full
/// output.
pub fn[S : Stepper] check_truncation(
  make : () -> S,
  input : BytesView,
  full : Transcript,
  max_prefixes~ : Int32 = 256,
) -> Unit raise {
  let n = input.length()
  let count = n.min(max_prefixes)
  for i in 0..<count {
    let cut = if n <= max_prefixes {
      i
    } else {
      (i.to_int64() * n.to_int64() / count.to_int64()).to_int()
    }
    let run = drive(make(), input[:cut])
    match run.error {
      Some(Truncated) => ()
      None =>
        if !starts_with(full.output, run.output) {
          fail("the first \{cut} bytes end cleanly with other output")
        }
      Some(kind) =>
        fail(
          "the first \{cut} bytes raise \{@debug.to_string(kind)}, not Truncated",
        )
    }
  }
}

///|
fn starts_with(whole : Bytes, prefix : Bytes) -> Bool {
  prefix.length() <= whole.length() && whole[:prefix.length()] == prefix[:]
}

///|
/// Checks what bytes after a valid `input` do. Each of `garbage` (bytes the
/// format cannot read as the start of another member) raises
/// `TrailingData`. A single extra byte, whatever it is, raises
/// `TrailingData`, or `Truncated` when the format could read it as the start
/// of another member.
pub fn[S : Stepper] check_trailing(
  make : () -> S,
  input : BytesView,
  garbage~ : Array[Bytes],
) -> Unit raise {
  for extra in garbage {
    let run = drive(make(), [..input, ..extra])
    if run.error != Some(TrailingData) {
      fail("trailing \{extra} gives \{describe(run)}, not TrailingData")
    }
  }
  for byte in [b'\x00', b'\x01', b'\x28', b'\xff'] {
    let run = drive(make(), [..input, byte])
    if !(run.error is Some(TrailingData | Truncated)) {
      fail("a trailing \{byte} gives \{describe(run)}")
    }
  }
}

///|
/// Checks that `reset` forgets everything: a codec that ran over the first
/// half of `a` (or over `a` until an error), once reset, decodes `b` exactly
/// as a fresh one does.
pub fn[S : Stepper] check_reset(
  make : () -> S,
  a : BytesView,
  b : BytesView,
) -> Unit raise {
  let fresh = drive(make(), b)
  let used = make()
  let _ = drive(used, a[:a.length() / 2])
  used.reset()
  let again = drive(used, b)
  if !again.agrees(fresh) {
    fail("after reset: \{describe(again)}, fresh: \{describe(fresh)}")
  }
}

///|
/// Runs `rounds` corrupted copies of `input` (bits flipped, bytes replaced,
/// inserted, deleted, or the tail cut) through the codec under the
/// contract's checks, and returns how often each outcome happened, by name.
/// A corrupted input may decode or raise any `CodecError`; breaking the
/// contract fails.
pub fn[S : Stepper] fuzz(
  make : () -> S,
  input : BytesView,
  seed~ : UInt32,
  rounds~ : Int32,
  memory_limit~ : Int32? = None,
) -> Map[String, Int32] raise {
  let rng = Rng::new(seed)
  let outcomes : Map[String, Int32] = Map([])
  for _ in 0..<rounds {
    let mutated = mutate(rng, input)
    let run = drive(
      make(),
      mutated,
      input_sizes=Sizes::random(rng.below(1 << 20).reinterpret_as_uint(), 300),
      output_sizes=Sizes::random(rng.below(1 << 20).reinterpret_as_uint(), 3000),
      memory_limit~,
    )
    let name = match run.error {
      None => "decoded"
      Some(LimitExceeded(limit)) =>
        "LimitExceeded(\{@debug.to_string(limit.resource)})"
      Some(kind) => @debug.to_string(kind)
    }
    outcomes.set(name, outcomes.get_or_default(name, 0) + 1)
  }
  outcomes
}

///|
fn mutate(rng : Rng, input : BytesView) -> Bytes {
  let bytes = input.to_array()
  if bytes.is_empty() {
    return Bytes::from_array([rng.below(256).to_byte()])
  }
  let at = rng.below(bytes.length())
  match rng.below(5) {
    0 => bytes[at] = bytes[at] ^ (1 << rng.below(8)).to_byte()
    1 => bytes[at] = rng.below(256).to_byte()
    2 => bytes.insert(at, rng.below(256).to_byte())
    3 => ignore(bytes.remove(at))
    _ => bytes.truncate(at)
  }
  Bytes::from_array(bytes)
}
