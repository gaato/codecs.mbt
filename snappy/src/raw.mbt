// Snappy's raw format (format_description.txt): the uncompressed length as
// a varint, then elements: literals and copies of 1 to 64 bytes from up to
// 2^32 - 1 bytes back. The encoder works as snappy's CompressFragment does,
// on fragments of 64 KiB with a hash table of up to 2^14 entries.

///|
/// The fragments the encoder compresses apart, and the framing format's
/// most uncompressed bytes in a chunk.
const BLOCK_SIZE : Int32 = 65536

///|
/// The most output a raw stream can describe per byte of it: a copy of 64
/// bytes takes 3 (a 2-byte offset), so no stream of `n` bytes writes more
/// than `22 * n`.
const MAX_EXPANSION : Int64 = 22

///|
fn corrupt(message : String) -> @codec.CodecError {
  @codec.CodecError(Corrupt, message)
}

///|
/// The uncompressed length at the start of a raw stream, and the bytes its
/// varint takes: at most 5, for a length below 2^32.
fn read_length(input : BytesView) -> (Int64, Int32) raise @codec.CodecError {
  let mut value = 0L
  for i in 0..<5 {
    guard i < input.length() else {
      raise @codec.CodecError(Truncated, "the input ends inside the length")
    }
    let b = input[i].to_int64()
    value = value | ((b & 0x7FL) << (7 * i))
    if (b & 0x80L) == 0L {
      guard value <= 0xFFFFFFFFL else {
        raise corrupt("a length of 2^32 or more")
      }
      return (value, i + 1)
    }
  }
  raise corrupt("a length of more than 5 bytes")
}

///|
/// The error at `op`, recorded in `written`: only error paths take it.
fn stopped(
  written : Ref[Int32],
  op : Int32,
  message : String,
) -> @codec.CodecError {
  written.val = op
  corrupt(message)
}

///|
/// Decodes the elements of `src` into `dst[start:end]`, which they must fill
/// exactly; a copy reaches back no further than `start`. On an error,
/// `written` holds where the bytes decoded before it end, so that a
/// streaming decoder hands them out first, as the contract has it.
fn decode_elements(
  src : BytesView,
  dst : FixedArray[Byte],
  start : Int32,
  end : Int32,
  written : Ref[Int32],
) -> Unit raise @codec.CodecError {
  let n = src.length()
  let mut ip = 0
  let mut op = start
  while ip < n {
    let tag = src[ip].to_int()
    ip += 1
    if (tag & 3) == 0 {
      let mut len = (tag >> 2).to_int64()
      if len >= 60L {
        let k = (len - 59L).to_int()
        guard k <= n - ip else {
          raise stopped(written, op, "a literal's length cut short")
        }
        len = 0L
        for j in 0..<k {
          len = len | (src[ip + j].to_int64() << (8 * j))
        }
        ip += k
      }
      len = len + 1L
      guard len <= (n - ip).to_int64() && len <= (end - op).to_int64() else {
        raise stopped(written, op, "a literal past the input or the length")
      }
      let len = len.to_int()
      @blit.from_view(dst, op, src[ip:ip + len])
      ip += len
      op += len
      continue
    }
    let (len, offset) = match tag & 3 {
      1 => {
        guard ip < n else { raise stopped(written, op, "a copy cut short") }
        let offset = (tag >> 5 << 8) | src[ip].to_int()
        ip += 1
        (4 + ((tag >> 2) & 7), offset.to_int64())
      }
      2 => {
        guard n - ip >= 2 else {
          raise stopped(written, op, "a copy cut short")
        }
        let offset = src[ip].to_int() | (src[ip + 1].to_int() << 8)
        ip += 2
        (1 + (tag >> 2), offset.to_int64())
      }
      _ => {
        guard n - ip >= 4 else {
          raise stopped(written, op, "a copy cut short")
        }
        let mut offset = 0L
        for j in 0..<4 {
          offset = offset | (src[ip + j].to_int64() << (8 * j))
        }
        ip += 4
        (1 + (tag >> 2), offset)
      }
    }
    guard offset > 0L && offset <= (op - start).to_int64() else {
      raise stopped(written, op, "a copy from before the start of the data")
    }
    guard len <= end - op else {
      raise stopped(written, op, "a copy past the length")
    }
    let from = op - offset.to_int()
    if offset.to_int() >= len {
      @blit.bytes(dst, op, dst, from, len)
    } else {
      // Overlapping: the copy repeats bytes it writes.
      @blit.forward(dst, op, from, len)
    }
    op += len
  }
  guard op == end else {
    raise stopped(written, op, "fewer bytes than the length says")
  }
}

///|
/// Decodes a whole raw Snappy stream. `max_output` caps the decoded length
/// (2^31 - 1 by default, what an array holds): past it the stream raises
/// `LimitExceeded({ resource: Output, .. })` before anything is allocated.
/// A length that the stream's bytes cannot make raises `Corrupt`, before
/// anything is allocated too.
pub fn decompress_raw(
  input : BytesView,
  max_output? : Int32,
) -> Bytes raise @codec.CodecError {
  let (length, used) = read_length(input)
  let limit = match max_output {
    Some(m) => m.max(0).to_int64()
    None => 0x7FFFFFFFL
  }
  guard length <= limit else {
    raise @codec.CodecError(
      LimitExceeded({
        resource: Output,
        needed: Some(length.reinterpret_as_uint64()),
        limit: limit.reinterpret_as_uint64(),
      }),
      "the stream says \{length} bytes, over \{limit}",
    )
  }
  let rest = input[used:]
  guard length <= MAX_EXPANSION * rest.length().to_int64() else {
    raise corrupt("a length the stream's bytes cannot make")
  }
  let out = FixedArray::make(length.to_int(), b'\x00')
  decode_elements(rest, out, 0, out.length(), Ref(0))
  Bytes::from_array(out[:])
}

///|
/// The most bytes `compress_raw` writes for `n` bytes of input: snappy's
/// `MaxCompressedLength`, `32 + n + n / 6`. A negative `n` counts as 0.
pub fn raw_compress_bound(n : Int64) -> Int64 {
  let n = n.max(0L)
  guard n <= 0x3FFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  32L + n + n / 6L
}

///|
/// Compresses `input` into a whole raw Snappy stream, as snappy's
/// `Compress` does: the length, then each 64 KiB fragment on its own.
/// Inputs over 1,840,700,242 bytes abort: the output is allocated at its
/// bound first, and theirs passes 2^31 - 1 bytes, the most an array holds.
pub fn compress_raw(input : BytesView) -> Bytes {
  let bound = raw_compress_bound(input.length().to_int64())
  guard bound <= 0x7FFFFFFFL else {
    abort(
      "compress_raw: \{input.length()} bytes, whose bound passes 2^31 - 1 bytes",
    )
  }
  let out = Writer::new(bound.to_int())
  out.varint(input.length())
  let table = FixedArray::make(1 << MAX_HASH_BITS, (0 : UInt16))
  let mut start = 0
  while start < input.length() {
    let end = (start + BLOCK_SIZE).min(input.length())
    compress_fragment(input, start, end, out, table)
    start = end
  }
  out.to_bytes()
}
