# gaato/crc

Cyclic redundancy checks in pure MoonBit, for Native, JS, Wasm and Wasm GC.
Use it to compute or verify the CRC a file format or protocol specifies:
CRC-32 for ZIP, gzip and PNG, CRC-32C for iSCSI, ext4 and Snappy, CRC-64/XZ
for `.xz`, or a CRC such as CRC-16/MODBUS by its catalogue name.

- Any CRC up to 64 bits wide, from its parameters, or one of the 112 in the
  [reveng catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm) by
  name.
- Data in pieces: a running digest, or a CRC continued from a stored one.
- `combine`: the CRC of two pieces joined, from the two CRCs and the second
  piece's length, without the data. Use it for pieces checksummed in parallel or
  on different machines.
- CRC-32, CRC-32C and CRC-64/XZ are computed eight bytes at a time.

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

**Pick the CRC by name, not by width.** CRC-32 and CRC-32C are both 32 bits but
use different polynomials and give different values. Take the name from the
format's specification. `Crc::named` accepts the catalogue's name or an alias,
in any case ("CRC-32" is CRC-32/ISO-HDLC), and returns `None` for anything else.

**Continuing a CRC.** `update(crc, data)` continues from the CRC of the data so
far, as zlib's `crc32` does: `update(checksum(a), b)` equals `checksum(a + b)`,
and `checksum(b"")` is the start. `crc32_update`, `crc32c_update` and
`crc64_xz_update` are the same as plain functions, starting from 0.

**Combining.** `combine(crc_a, crc_b, len_b)` takes the second piece's length
in bytes, and runs in time logarithmic in that length.

## Custom parameters

`Crc::new(width~, poly~, init?, reflect_in?, reflect_out?, xor_out?)` takes the
parameters as the reveng catalogue writes them: `poly` without its top term,
`init` as the register's start, `reflect_in` for input taken least significant
bit first, `reflect_out` (the same as `reflect_in` unless given), and
`xor_out`. A CRC's parameters are readable fields.

`Crc::new` aborts on parameters a program cannot mean: a width outside 1 to 64,
or a `poly`, `init` or `xor_out` that does not fit the width. For parameters
read from a file or configuration, use `Crc::try_new`, which takes the same
arguments and returns `Err` with the reason. No other function raises or
aborts.

## Not included

CRCs wider than 64 bits, messages that are not whole bytes, hardware CRC
instructions, and checksums that are not CRCs (Adler-32, xxHash). For SHA-2
and other cryptographic hashes, use `moonbitlang/x/crypto`.

## Links

- [The reveng CRC catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm):
  the tests check every named CRC against its check value
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/crc/RESOURCE_BOUNDS.md)
  and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/crc/TEST_COVERAGE.md)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/crc/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
