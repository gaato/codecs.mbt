///|
fn decode64(s : String) -> Bytes {
  @base64.decode(s, ignore_whitespace=true) catch {
    _ => abort("bad base64")
  }
}

///|
/// The raw DEFLATE data of a member `gzip -n` wrote: after its 10-byte
/// header and before its 8-byte trailer.
fn gzip_body(gz : Bytes) -> Bytes {
  guard gz[3] == b'\x00' else { abort("gzip: header with fields") }
  gz[10:gz.length() - 8].to_owned()
}

///|
/// Runs every benchmark of a test, first each for at least 300 ms and 3
/// times, then each measured, after a first measurement that is not counted.
/// On JS and Wasm the first benchmarks of a run otherwise take up to twice
/// as long as the same code measured later, which would favour whichever
/// package comes last.
fn run_all(b : @bench.T, benches : Array[(String, () -> Unit)]) -> Unit {
  for named in benches {
    let start = @env.now()
    let mut runs = 0
    while runs < 3 || @env.now() - start < 300 {
      (named.1)()
      runs += 1
    }
  }
  // The first measurement of a run is slow on Wasm whatever it measures:
  // it is taken once more, apart, and not counted.
  if benches.get(0) is Some(first) {
    b.bench(name="(warm-up) \{first.0}", first.1)
  }
  for named in benches {
    b.bench(name=named.0, named.1)
  }
}

///|
/// The decoders left out on this target: gmlewis/flate's decoder recurses
/// once per match, and overflows the stack of JS, Wasm and Wasm GC on the
/// 512 KiB text (the whole run stops on Wasm and Wasm GC).
#cfg(target="native")
fn left_out() -> Array[String] {
  []
}

///|
#cfg(not(target="native"))
fn left_out() -> Array[String] {
  ["gmlewis/flate 0.36.17"]
}

///|
/// Adds a benchmark of each decoder over `input`, which every one of them
/// must first decode to `size` bytes.
fn add_whole(
  benches : Array[(String, () -> Unit)],
  b : @bench.T,
  decoders : Array[@compare.Whole],
  label : String,
  input : Bytes,
  size : Int32,
) -> Unit {
  for d in decoders {
    if left_out().contains(d.name) {
      continue
    }
    let decode = d.decode
    let n = decode(input).length() catch {
      e => abort("\{d.name} \{label}: \{e}")
    }
    assert_eq(n, size) catch {
      _ => abort("\{d.name} \{label}: \{n} bytes, not \{size}")
    }
    benches.push(
      (
        "\{d.name} \{label}",
        () => b.keep(decode(input).length() catch { _ => abort("") }),
      ),
    )
  }
}

///|
/// Adds a benchmark of each encoder over `input` at its default level and,
/// if it is another, at its highest.
fn add_encode(
  benches : Array[(String, () -> Unit)],
  b : @bench.T,
  encoders : Array[@compare.Compress],
  label : String,
  input : Bytes,
) -> Unit {
  for e in encoders {
    let encode = e.encode
    let levels = if e.default_level == e.max_level {
      [("default", e.default_level)]
    } else {
      [("default", e.default_level), ("max", e.max_level)]
    }
    for named in levels {
      let (which, level) = named
      benches.push(
        (
          "\{e.name} \{which} \{label}",
          () => b.keep(encode(input, level).length() catch { _ => abort("") }),
        ),
      )
    }
  }
}
