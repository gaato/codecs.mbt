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
  priv mut first : UInt32
  priv mut second : UInt32
  priv mut third : UInt32
}

///|
/// Initial repeat offsets of a frame.
pub fn Repeats::Repeats() -> Repeats {
  { first: 1, second: 4, third: 8, }
}

///|
/// Restores the frame's initial repeat offsets.
pub fn Repeats::reset(self : Repeats) -> Unit {
  self.set(1, 4, 8)
}

///|
/// Sets the three repeat offsets, as a formatted dictionary gives them.
pub fn Repeats::set(
  self : Repeats,
  r1 : UInt32,
  r2 : UInt32,
  r3 : UInt32,
) -> Unit {
  self.first = r1
  self.second = r2
  self.third = r3
}

///|
/// Copies history, for a speculative block or match search.
pub fn Repeats::copy_from(self : Repeats, other : Repeats) -> Unit {
  self.set(other.first, other.second, other.third)
}

///|
/// Recent distance at index 0..2, for the match finder.
pub fn Repeats::get(self : Repeats, index : Int32) -> Distance {
  Distance(
    match index {
      0 => self.first
      1 => self.second
      2 => self.third
      _ => abort("repeat offset index out of bounds")
    },
  )
}

///|
/// The distance a repeat index (0..3) denotes.
#inline
fn Repeats::at(self : Repeats, index : Int32) -> UInt32 {
  if index == 3 {
    self.first - 1
  } else {
    let Distance(d) = self.get(index)
    d
  }
}

///|
/// Resolves a value and advances history per RFC 8878 section 3.1.1.5.
/// A decoder must reject a returned zero distance.
pub fn Repeats::resolve(
  self : Repeats,
  value : OffsetValue,
  ll : Int32,
) -> Distance {
  let OffsetValue(v) = value
  if v > 3 {
    let d = v - 3
    self.third = self.second
    self.second = self.first
    self.first = d
    Distance(d)
  } else {
    let index = v.reinterpret_as_int() - 1 + (if ll == 0 { 1 } else { 0 })
    let d = self.at(index)
    if index != 0 {
      if index > 1 {
        self.third = self.second
      }
      self.second = self.first
      self.first = d
    }
    Distance(d)
  }
}

///|
/// Converts a raw distance to its first matching repeat value if any,
/// otherwise to a regular offset. Advances history only for that value.
pub fn Repeats::encode(
  self : Repeats,
  distance : Distance,
  ll : Int32,
) -> OffsetValue {
  let Distance(d) = distance
  let raw = d + 3
  let value : UInt32 = if ll == 0 {
    if d == self.second {
      1
    } else if d == self.third {
      2
    } else if d == self.first - 1 {
      3
    } else {
      raw
    }
  } else if d == self.first {
    1
  } else if d == self.second {
    2
  } else if d == self.third {
    3
  } else {
    raw
  }
  let value = OffsetValue(value)
  self.resolve(value, ll) |> ignore
  value
}
