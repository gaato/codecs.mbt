///|
/// A raw, positive backward match distance, before repeat offset coding.
#derive(Eq)
pub(all) struct Distance(UInt32)

///|
/// Equality of raw distances.
pub extend Distance with Eq::{equal, not_equal}

///|
/// RFC Offset_Value: repeat 1..3, or raw distance + 3. UInt32 also holds
/// values whose offset extra field has 31 bits.
pub(all) struct OffsetValue(UInt32)

///|
/// The frame's recent distances, initialized to 1, 4, 8.
pub struct Repeats {
  priv values : FixedArray[UInt32]
}

///|
/// Initial repeat offsets of a frame.
pub fn Repeats::Repeats() -> Repeats {
  { values: [1, 4, 8], }
}

///|
/// Restores the frame's initial repeat offsets.
pub fn Repeats::reset(self : Repeats) -> Unit {
  self.values[0] = 1
  self.values[1] = 4
  self.values[2] = 8
}

///|
/// Copies history, for a speculative block or match search.
pub fn Repeats::copy_from(self : Repeats, other : Repeats) -> Unit {
  for i in 0..<3 {
    self.values[i] = other.values[i]
  }
}

///|
/// Recent distance at index 0..2, for the match finder.
pub fn Repeats::get(self : Repeats, index : Int32) -> Distance {
  Distance(self.values[index])
}

///|
/// Resolves a value and advances history. This is the single location for
/// the zero-literal shift and repeat-3-minus-1 (RFC 8878 section 3.1.1.5).
/// A decoder must reject a returned zero distance.
pub fn Repeats::resolve(
  self : Repeats,
  value : OffsetValue,
  ll : Int32,
) -> Distance {
  let OffsetValue(v) = value
  let r = self.values
  if v > 3 {
    let d = v - 3
    r[2] = r[1]
    r[1] = r[0]
    r[0] = d
    Distance(d)
  } else {
    let index = v.reinterpret_as_int() - 1 + (if ll == 0 { 1 } else { 0 })
    let d = if index == 3 { r[0] - 1 } else { r[index] }
    if index != 0 {
      if index > 1 {
        r[2] = r[1]
      }
      r[1] = r[0]
      r[0] = d
    }
    Distance(d)
  }
}

///|
/// Converts a raw distance in exactly one place. Tries all repeat values
/// through the same resolver, avoiding a second copy of the shift rule.
/// Advances history only for the chosen value; a normal distance is valid
/// even when it equals a recent distance.
pub fn Repeats::encode(
  self : Repeats,
  distance : Distance,
  ll : Int32,
) -> OffsetValue {
  // Keep the original history in scalars and undo unsuccessful trials.
  // A temporary Repeats would allocate an object and array per sequence.
  let first = self.values[0]
  let second = self.values[1]
  let third = self.values[2]
  for v in 1U..<=3U {
    let value = OffsetValue(v)
    if self.resolve(value, ll) == distance {
      return value
    }
    self.values[0] = first
    self.values[1] = second
    self.values[2] = third
  }
  let Distance(d) = distance
  let value = OffsetValue(d + 3)
  self.resolve(value, ll) |> ignore
  value
}
