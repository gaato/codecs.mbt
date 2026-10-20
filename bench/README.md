# gaato/codec_bench

Unpublished. Benchmarks of the workspace's codecs:

```sh
MOON_CC=cc taskset -c 2 moon bench --release --target native -p gaato/codec_bench
```

The inputs (`src/data_test.mbt`) are a deterministic text and a deterministic
binary stream, compressed by the reference implementations (`zstd -3`, and
the `brotli` Python module at quality 9), so that the decoders meet what
common encoders produce. `scripts/gen_bench_data.py` regenerates them; it
needs the `zstd` command and the `brotli` Python module.

Pin the run to one CPU and compare runs taken alternately: differences of a
few percent between single runs are noise.
