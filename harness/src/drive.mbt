///|
/// Everything a run of a codec over one input shows: what it wrote, the
/// events it stopped at, and the kind of error that ended it, if any. Two
/// runs agree when these agree; how many steps they took and how much
/// memory they peaked at are kept for the bounds checks.
pub(all) struct Transcript {
  output : Bytes
  events : Array[String]
  error : @codec.ErrorKind?
  steps : Int32
  peak_memory : Int32
}

///|
/// Whether two runs agree on output, events and error.
pub fn Transcript::agrees(self : Transcript, other : Transcript) -> Bool {
  self.output == other.output &&
  self.events == other.events &&
  self.error == other.error
}

///|
/// A sequence of chunk sizes: how much input to hand over, or how much room
/// to give, at each step.
pub(all) struct Sizes {
  next : () -> Int32
  label : String
}

///|
/// The same size every time.
pub fn Sizes::fixed(n : Int32) -> Sizes {
  { next: () => n, label: n.to_string(), }
}

///|
/// Sizes in `1..=max`, drawn from a seeded generator.
pub fn Sizes::random(seed : UInt32, max : Int32) -> Sizes {
  let rng = Rng::new(seed)
  { next: () => 1 + rng.below(max), label: "random(\{seed}, \{max})", }
}

///|
/// Steps limit for one run: far above any real stream's, low enough that a
/// codec that stops making progress fails instead of hanging.
let max_steps : Int32 = 50_000_000

///|
/// Runs `codec` over `input`, handing it chunks of `input_sizes` and room of
/// `output_sizes`, with `end` set once the last chunk is handed over. Checks
/// after every step that the codec kept the contract:
///
/// - `NeedMoreInput` consumed everything handed over, and never comes after
///   `end`: at the end a codec finishes or reports `Truncated`;
/// - `NeedMoreOutput` filled the room, and a step with room makes progress;
/// - `Done` comes only with `end` and every byte consumed;
/// - memory never shrinks during a stream and never exceeds `memory_limit`;
/// - an error sticks: another step raises the same kind.
pub fn[S : Stepper] drive(
  codec : S,
  input : BytesView,
  input_sizes~ : Sizes = Sizes::fixed(1 << 20),
  output_sizes~ : Sizes = Sizes::fixed(1 << 16),
  memory_limit~ : Int32? = None,
) -> Transcript raise {
  let output = Buffer()
  let events = []
  let mut pos = 0
  let mut pending = input[0:0]
  let mut steps = 0
  let mut memory = codec.memory_usage()
  let mut peak = memory
  for ;; {
    if pending.length() == 0 && pos < input.length() {
      let next = (pos + (input_sizes.next)().max(1)).min(input.length())
      pending = input[pos:next]
      pos = next
    }
    let end = pos == input.length()
    let room = (output_sizes.next)().max(1)
    let step = codec.step(pending, room, end~) catch {
      @codec.CodecError(kind, _) as err => {
        // The error sticks, whatever the next step is handed.
        let again = try codec.step(pending, room, end~) catch {
          @codec.CodecError(next, _) => next
          other => raise other
        } noraise {
          _ => fail("after \{@debug.to_string(err)}, the next step succeeded")
        }
        if again != kind {
          fail(
            "after \{@debug.to_string(kind)}, the next step raised \{@debug.to_string(again)}",
          )
        }
        return {
          output: output.to_bytes(),
          events,
          error: Some(kind),
          steps,
          peak_memory: peak,
        }
      }
      other => raise other
    }
    steps += 1
    if steps > max_steps {
      fail("no end after \{max_steps} steps")
    }
    let now = codec.memory_usage()
    if now < memory {
      fail("memory went down from \{memory} to \{now} during a stream")
    }
    if memory_limit is Some(limit) && now > limit {
      fail("memory \{now} over the limit \{limit}")
    }
    memory = now
    peak = peak.max(now)
    output.write_bytes(step.produced)
    pending = pending[step.consumed:]
    match step.stop {
      Done => {
        if !end || pending.length() != 0 {
          fail(
            "Done with \{pending.length() + input.length() - pos} bytes unread",
          )
        }
        return {
          output: output.to_bytes(),
          events,
          error: None,
          steps,
          peak_memory: peak,
        }
      }
      NeedMoreInput => {
        if pending.length() != 0 {
          fail("NeedMoreInput with \{pending.length()} bytes unconsumed")
        }
        if end {
          fail("NeedMoreInput after the end of the input")
        }
      }
      NeedMoreOutput =>
        if step.produced.length() != room {
          fail(
            "NeedMoreOutput with \{room - step.produced.length()} bytes of room left",
          )
        }
      Event(event) => events.push(event)
    }
    if room > 0 &&
      step.consumed == 0 &&
      step.produced.length() == 0 &&
      step.stop is NeedMoreOutput {
      fail("a step with room made no progress")
    }
  }
}
