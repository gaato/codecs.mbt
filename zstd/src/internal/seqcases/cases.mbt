///|
/// A crafted encoded frame, its independently executed sequences, and
/// every block's selected (LL, OF, ML) modes.
pub(all) struct Case {
  name : String
  input : Bytes
  frame : Bytes
  modes : Array[(Int32, Int32, Int32)]
}

///|
/// Frames that force sequence boundaries a match finder need not choose.
pub fn cases() -> Array[Case] {
  let result = []
  for kind in 0..<8 {
    let out = @bits.BitPacker()
    out.write(32, 0xfd2fb528U.reinterpret_as_int())
    out.write(8, 0)
    out.write(8, 80) // windowLog 20; no checksum or content size.
    let writer = @seqenc.Writer()
    let block = @seqenc.Block()
    let plain : Array[Byte] = []
    let modes = []
    let mut seed = 8878U
    // Raw history crosses four blocks, then a match close to the window.
    if kind == 6 {
      for _ in 0..<8 {
        out.write(24, 131072 << 3)
        for _ in 0..<131072 {
          seed = seed * 1664525 + 1013904223
          let b = (seed >> 24).to_byte()
          plain.push(b)
          out.write(8, b.to_int())
        }
      }
    }
    let blocks = if kind == 2 || kind == 3 { 3 } else { 1 }
    for b in 0..<blocks {
      block.reset(writer.repeats, 131072)
      let count = match kind {
        0 => 4
        1 | 2 => 2000
        3 => 200
        4 => 0x7f00
        7 => 10
        _ => 1
      }
      for i in 0..<count {
        let ll = if kind == 7 {
          if i == 0 {
            64
          } else if i == 1 || i == 2 || i == 5 {
            1
          } else {
            0
          }
        } else if kind == 5 {
          65536
        } else if kind == 6 {
          0
        } else if i == 0 && plain.is_empty() {
          64
        } else if kind == 4 {
          0
        } else if kind == 3 {
          1
        } else if kind == 0 {
          i + 1
        } else if i % 100 < 98 {
          1
        } else {
          i % 2 + 2
        }
        let ml = if kind == 5 {
          65536
        } else if kind == 6 {
          65539
        } else if kind == 4 {
          3
        } else if kind == 3 {
          8
        } else {
          4 + i % 3
        }
        let distance = if kind == 7 {
          [1, 4, 8, 4, 1, 10, 9, 9, 9, 10][i]
        } else if kind == 6 {
          (1 << 20) - 1
        } else if kind == 0 {
          [1, 4, 8, 3][i]
        } else if kind == 3 || kind == 4 || kind == 5 {
          1
        } else if i % 100 < 98 {
          4
        } else {
          i % 2 + 8
        }
        for _ in 0..<ll {
          seed = seed * 1664525 + 1013904223
          let byte = (seed >> 24).to_byte()
          block.literal(byte)
          plain.push(byte)
        }
        block.add(ll, ml, @seqenc.Distance(distance.reinterpret_as_uint()))
        for _ in 0..<ml {
          plain.push(plain[plain.length() - distance])
        }
      }
      let body = @bits.BitPacker()
      let n = block.literal_count
      if n < 32 {
        body.write(3, 0)
        body.write(5, n)
      } else if n < 4096 {
        body.write(4, 4)
        body.write(12, n)
      } else {
        body.write(4, 12)
        body.write(20, n)
      }
      body.write_bytes(block.literals, 0, n)
      writer.write(body, block)
      modes.push(writer.modes())
      writer.commit(block)
      out.write(
        24,
        (body.pending() << 3) | 4 | (if b == blocks - 1 { 1 } else { 0 }),
      )
      let bytes = FixedArray::make(body.pending(), b'\x00')
      body.drain_into(bytes, 0) |> ignore
      out.write_bytes(bytes, 0, bytes.length())
    }
    let bytes = FixedArray::make(out.pending(), b'\x00')
    out.drain_into(bytes, 0) |> ignore
    result.push({
      name: [
        "predefined", "fse", "repeat-fse", "repeat-rle", "many-sequences", "long-extras",
        "window-offset", "repeat-edges",
      ][kind],
      input: Bytes::from_array(plain),
      frame: Bytes::from_array(bytes[:]),
      modes,
    })
  }
  result.push(treeless())
  result
}

///|
fn treeless() -> Case {
  let coder = @huffenc.HuffmanEncoder()
  let counts = FixedArray::makei(256, i => if i < 32 { 4 } else { 0 })
  let data = FixedArray::makei(128, i => (i % 32).to_byte())
  coder.build(counts) |> ignore
  let stream_size = coder.cost(counts) / 8 + 1
  let out = @bits.BitPacker()
  out.write(32, 0xfd2fb528U.reinterpret_as_int())
  out.write(8, 0)
  out.write(8, 56)
  for first in [true, false] {
    let payload = stream_size +
      (if first { coder.description_size() } else { 0 })
    out.write(24, ((3 + payload + 1) << 3) | 4 | (if first { 0 } else { 1 }))
    out.write(2, if first { 2 } else { 3 })
    out.write(2, 0)
    out.write(10, 128)
    out.write(10, payload)
    if first {
      coder.write_description(out)
    }
    coder.write_literals(out, data, 0, 128, four_streams=false)
    out.write(8, 0)
    if first {
      out.write(24, 1 << 3)
      out.write(8, 42)
      out.write(24, (100 << 3) | 2)
      out.write(8, 42)
    }
  }
  let frame = FixedArray::make(out.pending(), b'\x00')
  out.drain_into(frame, 0) |> ignore
  let literals = Bytes::from_array(data[:])
  {
    name: "treeless-across-raw-rle",
    input: literals + Bytes::make(101, b'\x2a') + literals,
    frame: Bytes::from_array(frame[:]),
    modes: [],
  }
}
