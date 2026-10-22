# gaato/codec_bench

Unpublished. Benchmarks of the workspace's codecs:

```sh
MOON_CC=cc taskset -c 2 moon bench --release --target native -p gaato/codec_bench
```

The inputs (`src/data_test.mbt`) are a deterministic text and a deterministic
binary stream, compressed by the reference implementations (`zstd -3`,
`brotli -q 9` and `gzip -6`), so that the decoders meet what common encoders
produce; the encoders compress what the decoders give back. The DEFLATE
benchmarks decode the raw DEFLATE data inside the gzip members.
`moon run scripts/gen_bench_data.mbtx` regenerates them; it needs the `zstd`,
`brotli` and `gzip` commands.

Pin the run to one CPU and compare runs taken alternately: differences of a
few percent between single runs are noise.

The PNG benchmarks decode a 512 x 384 8-bit RGB image, once as it is and
once interlaced (`src/png_data/`), filtered row by row as libpng chooses by
default and compressed by zlib; each runs through `gaato/png` and through
typst's `decode_png` for comparison. `moon run scripts/gen_png_vectors.mbtx`
regenerates them; it needs pypng.

`src/png_memory` is an executable that decodes those images ten times, so
that the peak memory of a target's build can be measured on its own, without
the compilation that `moon run` also counts:

```sh
moon build --release --target wasm
/usr/bin/time -f '%M KB' moonrun _build/wasm/release/build/gaato/codec_bench/png_memory/png_memory.wasm
```

