///|
/// A seeded pseudo-random generator (a 32-bit LCG), for reproducible checks.
pub struct Rng {
  mut state : UInt32
}

///|
pub fn Rng::new(seed : UInt32) -> Rng {
  { state: seed, }
}

///|
/// A number in `0..<bound`.
pub fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}
