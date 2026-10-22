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

On an Intel Core i5-10400F, pinned to one CPU, with MoonBit 0.10.16 (moon
0.1.20261016; moonrun for Wasm, Node 26.12.1 for JS, GCC 16.2 for Native), the
mean time to decode each image with gaato/png 0.1.0 and with typst 0.1.7, and
the peak memory of `png_memory`:

| Target | gaato/png | interlaced | typst | interlaced | `png_memory` peak |
|---|---:|---:|---:|---:|---:|
| Native | 2.31 ms | 3.21 ms | 1.52 ms | 2.31 ms | 4.6 MiB |
| Wasm | 3.85 ms | 5.43 ms | 3.10 ms | 5.46 ms | 26.0 MiB |
| Wasm GC | 3.46 ms | 4.40 ms | 3.48 ms | 4.37 ms | 30.3 MiB |
| JS | 5.70 ms | 6.39 ms | 36.1 ms | 43.2 ms | 67.7 MiB |

The peak is the process's, most of it the runtime and the compiled code: the
decoder itself holds 47,360 + 2 × (1 + 1,536) bytes for these images.

`src/png_corpus` decodes broken PNG files with gaato/png and with typst; see
[png/docs/robustness.md](../png/docs/robustness.md).
