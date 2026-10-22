# codecs.mbt

Streaming codecs in pure MoonBit, for Native, JS, Wasm and Wasm GC. Input can
arrive in chunks of any size, output goes into slices of any size, and memory
stays within limits the caller sets.

| Module | | Directory |
|---|---|---|
| [`gaato/codec`](https://mooncakes.io/docs/gaato/codec) | The error kinds and limits every codec reports in | [`codec/`](codec/) |
| [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes) | The contract of byte-stream codecs | [`codec_bytes/`](codec_bytes/) |
| [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd) | Zstandard (RFC 8878) decoder | [`zstd/`](zstd/) |
| [`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli) | Brotli (RFC 7932) decoder and encoder | [`brotli/`](brotli/) |
| [`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate) | DEFLATE (RFC 1951), zlib (RFC 1950) and gzip (RFC 1952) decoders and encoders | [`deflate/`](deflate/) |
| [`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image) | The contract of image decoders | [`codec_image/`](codec_image/) |
| [`gaato/png`](https://mooncakes.io/docs/gaato/png) | PNG and APNG decoder | [`png/`](png/) |

Each module has its own README, version and changelog.

The codecs implement one contract for each kind, described in
[CONTRACT.md](CONTRACT.md): code written against `gaato/codec_bytes` drives
any of the byte-stream codecs, and code written against `gaato/codec_image`
any image decoder. [ARCHITECTURE.md](ARCHITECTURE.md) describes how the
repository is laid out.

## Development

```sh
moon run scripts/gates.mbtx                     # check, test on every target, format, interfaces
moon run scripts/coverage_report.mbtx -- zstd   # coverage against the module's ledger
```

## License

Apache-2.0. See each module for the licenses of the test data and tables it
includes.
