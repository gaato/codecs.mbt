# codecs.mbt

Streaming codecs in pure MoonBit, for Native, JS, Wasm and Wasm GC. Input can
arrive in chunks of any size, output goes into slices of any size, and memory
stays within limits the caller sets.

| Module | | Directory |
|---|---|---|
| [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd) | Zstandard (RFC 8878) decoder | [`zstd/`](zstd/) |
| [`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli) | Brotli (RFC 7932) decoder and encoder | [`brotli/`](brotli/) |

Each module has its own README, version and changelog.

The codecs are being moved onto one shared contract for byte-stream codecs,
described in [CONTRACT.md](CONTRACT.md); [ARCHITECTURE.md](ARCHITECTURE.md)
describes how the repository is laid out.

## Development

```sh
scripts/gates.sh                  # check, test on every target, format, interfaces
scripts/coverage_report.sh zstd   # coverage against the module's ledger
```

## License

Apache-2.0. See each module for the licenses of the test data and tables it
includes.
