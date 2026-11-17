# Deflate64 (ZIP method 9)

`gaato/deflate/deflate64` is the explicit, decode-only package for Enhanced
Deflating. [PKWARE APPNOTE 4.4.5 and 5.6](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
identify ZIP method 9 and its 64 KiB sliding dictionary. The specific code
extensions match [zlib 1.3.1's inftree9.c](https://github.com/madler/zlib/blob/v1.3.1/contrib/infback9/inftree9.c)
and [infback9.c](https://github.com/madler/zlib/blob/v1.3.1/contrib/infback9/infback9.c):

| Property | DEFLATE | Deflate64 |
|---|---|---|
| Window | 32,768 bytes | 65,536 bytes |
| Length code 285 | 258, no extra bits | 3 plus 16 extra bits: 3 through 65,538 |
| Distance code 30 | Invalid | 32,769 plus 14 extra bits |
| Distance code 31 | Invalid | 49,153 plus 14 extra bits, up to 65,536 |
| Dynamic distance alphabet | Up to 30 code lengths in this decoder, as in zlib (RFC 1951 lets a header declare 32, with codes 30 and 31 never used) | Up to 32 code lengths, all usable |

The internal inflater selects its window size, mask, fixed tables and table
alphabets at construction. The shared slow units use these plain fields.
`fast.mbt`, including the DEFLATE fast loop, is unchanged; Deflate64 uses a
separate driver chosen once per step. Its 16-bit length extra field has a
separate decorated-entry kind, and its signed packed distance entries are
read with an unsigned high-bit extraction.

A match is read atomically before output starts. The maximum unit takes 60
bits (15 + 16 + 15 + 14), so an incomplete unit can retain seven input bytes;
the existing eight-byte stash suffices. A match longer than the 65,536-byte
ring resumes through a separate copy state. Only the bounded ring is kept,
and decoded bytes before an error are handed out before the error is raised.

The per-instance element payload is 79,384 bytes: the ordinary decoder's
46,592 plus 32,768 additional window bytes, two extra distance-table entries
(8 bytes), two additional distance lengths (8 bytes), and two extra builder
sort slots (8 bytes). Shared fixed tables and runtime object headers are not
counted. There is no dictionary option and no encoder; ZIP framing, member
sizes and CRC checks belong to the enclosing ZIP reader.

## Reproducing the vectors

```sh
moon run deflate/scripts/gen_deflate64_vectors.mbtx --check
```

The generator uses `7z a -tzip -mm=Deflate64`, with one compression thread,
and extracts the compressed member using the central-directory size and the
local header's data offset. This handles data descriptors without including
ZIP metadata in the pins. It checks method 9 and pins both the raw stream's
SHA-256 and the expected output's SHA-256. The initial four fixtures were
made with 7-Zip 26.04. `--check` regenerates them, and skips with a message if
`7z` is unavailable; CI installs `7zip` and the gates invoke the check.

Hand-built fixed and dynamic blocks test both extended distance codes, full
and nearly full windows, 16-bit lengths, 15-bit Huffman codewords, truncation,
trailing data and resets. The same streams run whole, byte by byte and under
random splits with small output slices on every target. The conformance
package applies the shared mutation and error-split harness to Deflate64.
