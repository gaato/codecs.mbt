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
