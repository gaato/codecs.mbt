# codecs.mbt

Streaming codecs in pure MoonBit, for Native, JS, Wasm and Wasm GC. Input can
arrive in chunks of any size, output goes into slices of any size, and memory
stays within limits the caller sets.

| Module | | Directory |
|---|---|---|
| [`gaato/codec`](https://mooncakes.io/docs/gaato/codec) | The error kinds and limits every codec reports in | [`codec/`](codec/) |
| [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes) | The contract of byte-stream codecs | [`codec_bytes/`](codec_bytes/) |
| [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd) | Zstandard (RFC 8878) decoder and encoder | [`zstd/`](zstd/) |
| [`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli) | Brotli (RFC 7932) decoder and encoder | [`brotli/`](brotli/) |
| [`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate) | DEFLATE (RFC 1951), zlib (RFC 1950) and gzip (RFC 1952) decoders and encoders | [`deflate/`](deflate/) |
| [`gaato/snappy`](https://mooncakes.io/docs/gaato/snappy) | Snappy's raw format, whole, and its framing format, streamed, decoders and encoders | [`snappy/`](snappy/) |
| [`gaato/lz4`](https://mooncakes.io/docs/gaato/lz4) | LZ4 frames, streamed, with checksums, dictionaries, skippable and legacy frames, and blocks; the encoder writes lz4's bytes | [`lz4/`](lz4/) |
| [`gaato/lzw`](https://mooncakes.io/docs/gaato/lzw) | LZW as GIF, TIFF, PDF and Unix compress (.Z) use it, decoder and encoder | [`lzw/`](lzw/) |
| [`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image) | The contract of image decoders | [`codec_image/`](codec_image/) |
| [`gaato/png`](https://mooncakes.io/docs/gaato/png) | PNG and APNG decoder | [`png/`](png/) |
| [`gaato/crc`](https://mooncakes.io/docs/gaato/crc) | CRCs of up to 64 bits by parameters or name, combined across pieces; fast CRC-32, CRC-32C and CRC-64/XZ | [`crc/`](crc/) |

Each module has its own README, version and changelog.

The codecs implement one contract for each kind, described in
[CONTRACT.md](CONTRACT.md): code written against `gaato/codec_bytes` drives
any of the byte-stream codecs, and code written against `gaato/codec_image`
any image decoder. [ARCHITECTURE.md](ARCHITECTURE.md) describes how the
repository is laid out.

## Development

```sh
moon run scripts/gates.mbtx                     # check, test on every target, coverage ledgers, proofs, format, interfaces
moon run scripts/gates.mbtx -- --full           # the same and the encoders' crosschecks, as CI runs
moon run scripts/coverage_report.mbtx -- zstd   # one module's coverage against its ledger
```

## License

Apache-2.0. See each module for the licenses of the test data and tables it
includes.
