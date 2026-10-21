///|
/// The FNV-1a hash of `data`, to tell outputs apart.
fn fnv1a(data : FixedArray[Byte], n : Int32, h : UInt32) -> UInt32 {
  let mut h = h
  for i in 0..<n {
    h = (h ^ data[i].to_uint()) * 16777619
  }
  h
}

///|
/// Compresses `input` whole at `level` into 64 KiB slices with `Finish`, as
/// a consumer would: the size and the hash of the stream.
fn compress(input : Bytes, level : Int32) -> (Int32, UInt32) {
  let encoder = @deflate.Encoder(level~)
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  let mut h : UInt32 = 2166136261
  for ;; {
    let status = encoder.step_into(rest, out, action=Finish)
    rest = rest[encoder.last_consumed():]
    total += encoder.last_produced()
    h = fnv1a(out, encoder.last_produced(), h)
    if status is Done {
      return (total, h)
    }
  }
}

///|
/// usage: ratio <levels, comma-separated> <min ms per measurement> <file>...
/// Prints, for each level and file: level, file, input size, output size,
/// MB/s (the mean over at least the given time and 2 runs; 0 skips timing)
/// and the FNV-1a hash of the output, tab-separated.
fn main {
  let args = @env.args()
  // On JS the arguments start with node and the script.
  let mut first = 1
  while first < args.length() && args[first].has_suffix(".js") {
    first += 1
  }
  let levels = args[first]
    .split(",")
    .map(s => @string.parse_int(s) catch { _ => abort("bad level \{s}") })
    .collect()
  let min_ms = @string.parse_int(args[first + 1]) catch {
    _ => abort("bad time")
  }
  for level in levels {
    for path in args[first + 2:] {
      let input = @fs.read_file_to_bytes(path) catch {
        _ => abort("cannot read \{path}")
      }
      let (size, hash) = compress(input, level)
      let mut speed = 0.0
      if min_ms > 0 {
        let mut spent = 0.0
        let mut runs = 0
        while runs < 2 || spent < min_ms.to_double() {
          let t0 = @env.now()
          ignore(compress(input, level))
          spent += (@env.now() - t0).to_double()
          runs += 1
        }
        speed = input.length().to_double() /
          (spent / runs.to_double() / 1000.0) /
          1.0e6
      }
      println(
        "\{level}\t\{path}\t\{input.length()}\t\{size}\t\{speed}\t\{hash}",
      )
    }
  }
}
