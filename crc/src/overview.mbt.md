# gaato/crc

Cyclic redundancy checks in pure MoonBit, for Native, JS, Wasm and Wasm GC: any CRC of up to 64 bits from its parameters, the 112 of the reveng catalogue by name, the CRC of two pieces from theirs (`combine`), and CRC-32, CRC-32C and CRC-64/XZ eight bytes at a time.

## Install

```sh
moon add gaato/crc
```

## Usage

```mbt check
///|
test {
  // The three that formats use most, as values and as plain functions.
  inspect(@crc.crc32.checksum(b"123456789"), content="3421780262")
  inspect(@crc.crc32c_update(0, b"123456789"), content="3808858755")
  // Any CRC of the catalogue by name, or from its parameters.
  let modbus = @crc.Crc::named("CRC-16/MODBUS").unwrap()
  inspect(modbus.checksum(b"123456789"), content="19255")
  let custom = @crc.Crc::new(
    width=16,
    poly=0x8005,
    init=0xFFFF,
    reflect_in=true,
  )
  inspect(custom.checksum(b"123456789"), content="19255")
  // In pieces: a running digest, or a CRC continued from the one so far.
  let d = @crc.crc32.digest()
  d.write(b"1234")
  d.write(b"56789")
  inspect(d.value(), content="3421780262")
  let head = @crc.crc32.checksum(b"1234")
  inspect(@crc.crc32.update(head, b"56789"), content="3421780262")
  // The CRC of the two pieces one after the other, from theirs and the
  // second's length, without the data.
  let tail = @crc.crc32.checksum(b"56789")
  inspect(@crc.crc32.combine(head, tail, 5), content="3421780262")
}
```

`Crc::new(width~, poly~, init?, reflect_in?, reflect_out?, xor_out?)` takes Ross Williams's parameters as the reveng catalogue writes them: `poly` without its top term, `init` the register's start, `reflect_in` for input taken least significant bit first, `reflect_out` (as `reflect_in` unless given) for a register reflected before output, and `xor_out`. `Crc::named` finds a CRC of the catalogue by its name or an alias, in any case ("CRC-32" is CRC-32/ISO-HDLC), and gives None for another. A CRC's parameters are readable fields.

`update(crc, data)` continues a CRC as zlib's `crc32` does: from the CRC of the data so far, with `checksum(b"")` for none, so that `update(checksum(a), b)` is `checksum(a + b)`. `combine(crc_a, crc_b, len_b)` gives the CRC of `a` then `b` from those of each and `b`'s length in bytes, in time logarithmic in the length, as zlib's `crc32_combine` does; it serves pieces computed apart, in parallel or on other machines.

`crc32`, `crc32c` and `crc64_xz`, and any `Crc` made with their parameters, take eight bytes at a time from tables computed at start-up (slice-by-8). `crc32_update`, `crc32c_update` and `crc64_xz_update` are the same as plain functions on `UInt32` and `UInt64`, starting from 0. Other CRCs take a byte at a time from a table of 256 entries made with the `Crc`.

Not included: CRCs wider than 64 bits (the catalogue's CRC-82/DARC), whose register does not fit a `UInt64`; messages that are not whole bytes; hardware CRC instructions, which MoonBit does not reach; and other checksums. Adler-32 and xxHash are not CRCs, and gaato/deflate and gaato/zstd keep theirs internal; for SHA-2 and other cryptographic hashes, use `moonbitlang/x/crypto`.

## Errors

None of the functions raises. `Crc::new` aborts for parameters a program cannot mean: a width outside 1 to 64, or a `poly`, `init` or `xor_out` that does not fit in the width. For parameters that come from data, such as a configuration, `Crc::try_new` takes the same arguments and gives `Err` with the reason instead. `combine` takes a negative length as 0.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/crc/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The reveng CRC catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm), whose check values the tests hold every named CRC to, and whose residues every CRC whose width is whole bytes
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/crc/RESOURCE_BOUNDS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/crc/TEST_COVERAGE.md)

## License

Apache-2.0.
