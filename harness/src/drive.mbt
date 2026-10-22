///|
/// Everything a run of a codec over one input shows: what it wrote (before
/// an error too), the events it stopped at, the kind of error that ended it,
/// if any, with its message, and how much input it consumed. Two runs agree
/// when these agree, but for the message; how many steps they took and how
/// much memory they peaked at are kept for the bounds checks.
pub(all) struct Transcript {
  output : Bytes
  events : Array[String]
  error : @codec.ErrorKind?
  /// The error's message, empty without an error.
  message : String
  consumed : Int32
  steps : Int32
  peak_memory : Int32
}

///|
/// Whether two runs agree on output, events and the kind of error, and,
/// without an error, on the input consumed. With an error the input consumed
/// may differ: a step takes all its input before it asks for more, so how far
/// past the error a run read depends on the split.
pub fn Transcript::agrees(self : Transcript, other : Transcript) -> Bool {
  self.output == other.output &&
  self.events == other.events &&
  self.error == other.error &&
  (self.error is Some(_) || self.consumed == other.consumed)
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
/// - a step with room that answers `NeedMoreOutput` makes progress (whether
///   the room was really full, the adapter checks: only it knows the unit
///   of output);
/// - `Done` comes only with `end` and every byte consumed; with
///   `first_member=true` (a codec that stops after the first member), `Done` may
///   leave input unread, and the transcript says how much was consumed;
/// - memory never exceeds `memory_limit`;
/// - a step that raises reports counts within what it was given, and its
///   output is part of the transcript;
/// - an error sticks: another step raises the same kind, consuming and
///   producing nothing.
pub fn[S : Stepper] drive(
  codec : S,
  input : BytesView,
  input_sizes~ : Sizes = Sizes::fixed(1 << 20),
  output_sizes~ : Sizes = Sizes::fixed(1 << 16),
  memory_limit~ : Int32? = None,
  first_member~ : Bool = false,
) -> Transcript raise {
  let output = Buffer()
  let events = []
  let mut pos = 0
  let mut pending = input[0:0]
  let mut steps = 0
  let mut peak = codec.memory_usage()
  for ;; {
    if pending.length() == 0 && pos < input.length() {
      let next = (pos + (input_sizes.next)().max(1)).min(input.length())
      pending = input[pos:next]
      pos = next
    }
    let end = pos == input.length()
    let room = (output_sizes.next)().max(1)
    let step = codec.step(pending, room, end~)
    steps += 1
    if steps > max_steps {
      fail("no end after \{max_steps} steps")
    }
    let now = codec.memory_usage()
    if memory_limit is Some(limit) && now > limit {
      fail("memory \{now} over the limit \{limit}")
    }
    peak = peak.max(now)
    output.write_bytes(step.produced)
    pending = pending[step.consumed:]
    match step.stop {
      Raised(kind, message) => {
        // The error sticks, whatever the next step is handed, and the next
        // step takes and gives nothing.
        let again = codec.step(pending, room, end~)
        guard again.stop is Raised(next, _) else {
          fail(
            "after \{@debug.to_string(kind)}, the next step answered \{@debug.to_string(again.stop)}",
          )
        }
        if next != kind {
          fail(
            "after \{@debug.to_string(kind)}, the next step raised \{@debug.to_string(next)}",
          )
        }
        if again.consumed != 0 || again.produced.length() != 0 {
          fail(
            "after \{@debug.to_string(kind)}, the next step reported \{again.consumed} consumed and \{again.produced.length()} produced",
          )
        }
        return {
          output: output.to_bytes(),
          events,
          error: Some(kind),
          message,
          consumed: pos - pending.length(),
          steps,
          peak_memory: peak,
        }
      }
      Done => {
        if !first_member && (!end || pending.length() != 0) {
          fail(
            "Done with \{pending.length() + input.length() - pos} bytes unread",
          )
        }
        return {
          output: output.to_bytes(),
          events,
          error: None,
          message: "",
          consumed: pos - pending.length(),
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
      NeedMoreOutput | Wrote => ()
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
