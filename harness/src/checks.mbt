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
    Some(kind) => "\{@debug.to_string(kind)} (\{run.message})"
    None => "no error"
  }
  "\{run.output.length()} bytes, \{run.events.length()} events, \{error}"
}

///|
/// Checks a codec that stops after the first member: over `first` followed
/// by `rest`, under every split of `splits()`, it ends with `Done` having
/// consumed exactly `first`, with the output `expected` (a run over `first`
/// alone). `make` builds a codec configured to stop after one member.
pub fn[S : Stepper] check_member(
  make : () -> S,
  first : BytesView,
  rest : BytesView,
  expected : Transcript,
) -> Unit raise {
  let input = Bytes::from_array([..first, ..rest])
  for split in splits() {
    let (input_sizes, output_sizes) = split
    let run = drive(
      make(),
      input,
      input_sizes~,
      output_sizes~,
      first_member=true,
    )
    if run.error is Some(_) ||
      run.output != expected.output ||
      run.events != expected.events ||
      run.consumed != first.length() {
      fail(
        "input in \{input_sizes.label}, output in \{output_sizes.label}: " +
        "\{describe(run)} after consuming \{run.consumed} of the first \{first.length()} bytes",
      )
    }
  }
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
/// of another member. Given all at once, a run that raises `TrailingData`
/// has consumed exactly `input`, and written all of `full`'s output (a run
/// over `input` alone).
pub fn[S : Stepper] check_trailing(
  make : () -> S,
  input : BytesView,
  full : Transcript,
  garbage~ : Array[Bytes],
) -> Unit raise {
  let at_end = (run : Transcript, what : String) => {
    if run.consumed != input.length() {
      fail(
        "\{what}: TrailingData after consuming \{run.consumed} of the stream's \{input.length()} bytes",
      )
    }
    if run.output != full.output {
      fail(
        "\{what}: TrailingData after \{run.output.length()} of the stream's \{full.output.length()} bytes of output",
      )
    }
  }
  for extra in garbage {
    let run = drive(make(), [..input, ..extra])
    if run.error != Some(TrailingData) {
      fail("trailing \{extra} gives \{describe(run)}, not TrailingData")
    }
    at_end(run, "trailing \{extra}")
  }
  for byte in [b'\x00', b'\x01', b'\x28', b'\xff'] {
    let run = drive(make(), [..input, byte])
    match run.error {
      Some(TrailingData) => at_end(run, "a trailing \{byte}")
      Some(Truncated) => ()
      _ => fail("a trailing \{byte} gives \{describe(run)}")
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
/// Checks rule 5 on an input that may be corrupt: a fresh codec runs over
/// `input` whole, then under two splits drawn from `seed` (small input chunks
/// with large room, large chunks with little room) and, for inputs and
/// outputs of at most `small` bytes, with the input a byte at a time and
/// with a byte of room. Every run must agree with the whole one: the same
/// output, everything written before an error included, and the same kind of
/// error. Returns the whole run.
pub fn[S : Stepper] check_error_splits(
  make : () -> S,
  input : BytesView,
  seed~ : UInt32,
  memory_limit~ : Int32? = None,
  small~ : Int32 = 4096,
) -> Transcript raise {
  let whole = drive(make(), input, memory_limit~)
  let rng = Rng::new(seed)
  let seed = () => rng.below(1 << 20).reinterpret_as_uint()
  let runs = [
    (Sizes::random(seed(), 64), Sizes::random(seed(), 4096)),
    (Sizes::random(seed(), 2000), Sizes::random(seed(), 7)),
  ]
  if input.length() <= small && whole.output.length() <= small {
    runs.push((Sizes::fixed(1), Sizes::fixed(1024)))
    runs.push((Sizes::fixed(1 << 20), Sizes::fixed(1)))
  }
  for split in runs {
    let (input_sizes, output_sizes) = split
    let run = drive(make(), input, input_sizes~, output_sizes~, memory_limit~)
    if run.agrees(whole) {
      continue
    }
    fail(
      "input in \{input_sizes.label}, output in \{output_sizes.label}: " +
      "\{describe(run)}, whole: \{describe(whole)}",
    )
  }
  whole
}

///|
/// Runs `rounds` corrupted copies of `input` (bits flipped, bytes replaced,
/// inserted, deleted, or the tail cut) through the codec under the
/// contract's checks, each under several splits that must agree
/// (`check_error_splits`), and returns how often each
/// outcome happened, by name. A corrupted input may decode or raise any
/// `CodecError`; breaking the contract fails.
pub fn[S : Stepper] fuzz(
  make : () -> S,
  input : BytesView,
  seed~ : UInt32,
  rounds~ : Int32,
  memory_limit~ : Int32? = None,
) -> Map[String, Int32] raise {
  let rng = Rng::new(seed)
  let outcomes : Map[String, Int32] = Map([])
  for round in 0..<rounds {
    let mutated = mutate(rng, input)
    let run = check_error_splits(
      make,
      mutated,
      seed=rng.below(1 << 20).reinterpret_as_uint(),
      memory_limit~,
    ) catch {
      e => fail("round \{round} from seed \{seed}: \{e}")
    }
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

///|
/// Checks an encoder against a decoder of its format: `input` is encoded
/// whole, then under every split of `splits()`, by a fresh encoder through
/// `ByteEncoder` (so `Finish` comes with the last chunk), and every
/// encoding must decode, with a fresh decoder given it whole, back to
/// `input`. Splitting does not matter to encoders either: every encoding
/// must equal the whole one. Byte-at-a-time splits are skipped for inputs
/// over `small` bytes. Returns the whole encoding.
pub fn[E : @codec_bytes.Encode, D : @codec_bytes.Decode] check_roundtrip(
  make_encoder : () -> E,
  make_decoder : () -> D,
  input : BytesView,
  encoder_memory_limit~ : Int32? = None,
  decoder_memory_limit~ : Int32? = None,
  small~ : Int32 = 1 << 16,
) -> Bytes raise {
  let encode = (input_sizes : Sizes, output_sizes : Sizes) => {
    let run = drive(
      ByteEncoder::new(make_encoder()),
      input,
      input_sizes~,
      output_sizes~,
      memory_limit=encoder_memory_limit,
    )
    let label = "input in \{input_sizes.label}, output in \{output_sizes.label}"
    if run.error is Some(kind) {
      fail("\{label}: encoding raised \{@debug.to_string(kind)}")
    }
    let decoded = drive(
      ByteDecoder::new(make_decoder()),
      run.output,
      memory_limit=decoder_memory_limit,
    )
    if decoded.error is Some(_) || decoded.output != input.to_owned() {
      fail("\{label}: the encoding decodes to \{describe(decoded)}")
    }
    (run, label)
  }
  let (whole, _) = encode(Sizes::fixed(1 << 20), Sizes::fixed(1 << 16))
  for split in splits() {
    let (input_sizes, output_sizes) = split
    let tiny = input_sizes.label == "1" || output_sizes.label == "1"
    if tiny && input.length() > small {
      continue
    }
    let (run, label) = encode(input_sizes, output_sizes)
    if !run.agrees(whole) {
      fail("\{label}: \{describe(run)}, whole: \{describe(whole)}")
    }
  }
  whole.output
}

///|
/// Checks `Flush`: `input` is encoded with a `Flush` after each of the
/// offsets `flush_at` (in increasing order) and `Finish` at the end. After
/// every flush, a fresh decoder given everything produced so far, without
/// `end`, must give out exactly the input up to that offset and ask for
/// more; the finished stream must decode to `input`. An encoder that
/// cannot flush raises `Unsupported` for `Flush`, and the check passes.
pub fn[E : @codec_bytes.Encode, D : @codec_bytes.Decode] check_flush(
  make_encoder : () -> E,
  make_decoder : () -> D,
  input : BytesView,
  flush_at~ : Array[Int32],
) -> Unit raise {
  let encoder = make_encoder()
  let stream = Buffer()
  let mut pos = 0
  for at in flush_at {
    if at < pos || at > input.length() {
      fail("flush offset \{at} out of order")
    }
    let flushed = encode_all(encoder, input[pos:at], Flush, stream) catch {
      @codec.CodecError(Unsupported, _) => return
      err => raise err
    }
    if flushed is Done {
      fail("a flush at \{at} ended the stream")
    }
    pos = at
    let decoded = decode_available(make_decoder(), stream.to_bytes())
    if decoded != input[:at].to_owned() {
      fail(
        "after a flush at \{at}, \{decoded.length()} bytes decode, not the input so far",
      )
    }
  }
  if encode_all(encoder, input[pos:], Finish, stream) != Done {
    fail("Finish did not end the stream")
  }
  let decoded = drive(ByteDecoder::new(make_decoder()), stream.to_bytes())
  if decoded.error is Some(_) || decoded.output != input.to_owned() {
    fail("the flushed stream decodes to \{describe(decoded)}")
  }
}

///|
/// Steps `encoder` over `input` with `action` until it has taken it all and
/// handed out what the action calls for, appending the output to `out`.
fn[E : @codec_bytes.Encode] encode_all(
  encoder : E,
  input : BytesView,
  action : @codec_bytes.EncodeAction,
  out : Buffer,
) -> Stop raise {
  let mut rest = input
  for ;; {
    let step = encode_step(encoder, rest, 1000, action)
    out.write_bytes(step.produced)
    rest = rest[step.consumed:]
    match step.stop {
      NeedMoreOutput => continue
      Raised(kind, message) => raise @codec.CodecError(kind, message)
      NeedMoreInput =>
        if rest.length() != 0 {
          fail("NeedMoreInput with input left")
        }
      _ => ()
    }
    return step.stop
  }
}

///|
/// Everything `decoder` gives out for `input` without `end`: it must take
/// all of it and ask for more, never answer `Done`.
fn[D : @codec_bytes.Decode] decode_available(
  decoder : D,
  input : BytesView,
) -> Bytes raise {
  let adapter = ByteDecoder::new(decoder)
  let out = Buffer()
  let mut rest = input
  for ;; {
    let step = adapter.step(rest, 4096, end=false)
    out.write_bytes(step.produced)
    rest = rest[step.consumed:]
    match step.stop {
      NeedMoreOutput => continue
      NeedMoreInput if rest.length() == 0 => return out.to_bytes()
      stop => fail("without end, a decoder answered \{@debug.to_string(stop)}")
    }
  }
}
