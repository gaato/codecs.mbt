// XXH32 with seed 0, fed incrementally, after the xxHash specification
// (https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md): the
// LZ4 frame format's header, block and content checksums.

///|
const PRIME32_1 : UInt32 = 0x9E3779B1

///|
const PRIME32_2 : UInt32 = 0x85EBCA77

///|
const PRIME32_3 : UInt32 = 0xC2B2AE3D

///|
const PRIME32_4 : UInt32 = 0x27D4EB2F

///|
const PRIME32_5 : UInt32 = 0x165667B1

///|
/// An XXH32 digest in progress: four lane accumulators, the bytes of an
/// unfinished 16-byte stripe, and the length so far.
priv struct Xxh32 {
  acc : FixedArray[UInt32]
  stripe : FixedArray[Byte]
  mut stripe_len : Int32
  mut total : UInt64
}

///|
fn Xxh32::new() -> Xxh32 {
  let h = {
    acc: FixedArray::make(4, 0),
    stripe: FixedArray::make(16, 0),
    stripe_len: 0,
    total: 0,
  }
  h.reset()
  h
}

///|
/// Starts a new digest.
fn Xxh32::reset(self : Xxh32) -> Unit {
  self.acc[0] = PRIME32_1 + PRIME32_2
  self.acc[1] = PRIME32_2
  self.acc[2] = 0
  self.acc[3] = 0U - PRIME32_1
  self.stripe_len = 0
  self.total = 0
}

///|
/// The XXH32 of `data`.
fn xxh32(data : BytesView) -> UInt32 {
  let h = Xxh32::new()
  h.update_view(data)
  h.digest()
}
