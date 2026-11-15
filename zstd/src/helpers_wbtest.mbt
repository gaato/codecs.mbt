///|
/// A test vector: a compressed stream and what it decodes to.
priv struct Vector {
  name : String
  compressed : String
  size : Int32
  sha256 : String
  /// The smallest `max_window_bits` that accepts the stream.
  window_bits : Int32
}

///|
fn Vector::input(self : Vector) -> Bytes {
  @base64.decode(self.compressed, ignore_whitespace=true) catch {
    _ => abort("bad base64 in vector \{self.name}")
  }
}

///|
/// Feeds `input` to `decoder` in chunks of `next_in()` bytes, into output
/// buffers of `next_out()` bytes (a `FixedArray` through `step_into`, or a
/// view through `step`), calling `check` after every step.
fn drive(
  decoder : Decoder,
  input : BytesView,
  next_in~ : () -> Int32,
  next_out~ : () -> Int32,
  fixed~ : Bool = true,
  check~ : (Decoder, Int32) -> Unit raise = (_, _) => (),
) -> Bytes raise {
  let out = Buffer()
  let mut pos = 0
  let mut pending = input[0:0]
  for ;; {
    if pending.length() == 0 && pos < input.length() {
      let next = (pos + next_in()).min(input.length())
      pending = input[pos:next]
      pos = next
    }
    let end = pos == input.length()
    let room = next_out()
    let buffer = FixedArray::make(room, b'\x00')
    let status = if fixed {
      decoder.step_into(pending, buffer, end~)
    } else {
      decoder.step(pending, buffer.mut_view(), end~)
    }
    check(decoder, room)
    pending = pending[decoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(buffer[:decoder.last_produced()])[:])
    match status {
      Done => return out.to_bytes()
      NeedMoreInput =>
        if pending.length() != 0 {
          fail("input left on NeedMoreInput")
        }
      NeedMoreOutput =>
        if decoder.last_consumed() == 0 && decoder.last_produced() == 0 {
          fail("no progress")
        }
    }
  }
}

///|
/// A seeded pseudo-random generator (a 32-bit LCG), for reproducible tests.
priv struct Rng {
  mut state : UInt32
}

///|
fn Rng::new(seed : UInt32) -> Rng {
  { state: seed, }
}

///|
/// A number in `0..<bound`.
fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
/// A frame that uses a dictionary, made by `zstd -D`
/// (zstd/scripts/gen_dict_vectors.mbtx).
priv struct DictVector {
  name : String
  /// The name of its dictionary in `dict_dictionaries`.
  dictionary : String
  compressed : String
  size : Int32
  sha256 : String
}

///|
fn DictVector::input(self : DictVector) -> Bytes {
  @base64.decode(self.compressed, ignore_whitespace=true) catch {
    _ => abort("bad base64 in vector \{self.name}")
  }
}

///|
/// The content of the dictionary named `name` in `dict_dictionaries`.
fn dict_bytes(name : String) -> Bytes {
  for named in dict_dictionaries {
    if named.0 == name {
      return @base64.decode(named.1, ignore_whitespace=true) catch {
        _ => abort("bad base64 in dictionary \{name}")
      }
    }
  }
  abort("no dictionary \{name}")
}
