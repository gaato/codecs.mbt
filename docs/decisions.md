# Decisions

Choices about how the codecs are built that the code alone does not explain:
what was decided, why, and what would reopen it. Most are speed work left
out or limited to some targets, kept here so that they are not taken up
again without new numbers. An entry stays as written; a later decision that
replaces it is a new entry that names it.

Reasons are of five kinds: **measured** (a benchmark or profile decided
it), **contract** (CONTRACT.md or a published bound would change),
**output** (an encoder's bytes would change), **toolchain** (what MoonBit
or a backend does or does not offer), **proof** (`moon prove` would lose a
proof). Times are from an Intel Core i5-10400F unless an entry says
otherwise; "five runs" means five alternating runs of each side.

## Hot loops without index checks

- **Date:** 2026-11-15
- **Decision:** the hot loops of decoders and encoders read and write
  through `unsafe_get` and `unsafe_set`, and through core's unaligned
  32- and 64-bit reads on native and Wasm, each access with its reason
  for being in bounds (AGENTS.md, "Speed work").
- **Reason:** measured. A checked access on Wasm calls two out-of-line
  helpers, and native spends a compare and a branch: the slice-by-8 CRC-32
  of 512 KiB took 1.25 ms checked and 0.53 ms unchecked on Wasm, 0.68 and
  0.48 ms on Wasm GC, 0.33 and 0.29 ms on native.
- **Reopen when:** the Wasm backend emits a checked access inline, or a
  wrong index is found that its stated reason did not rule out.

## SIMD on native and Wasm only, beside the proved reference

- **Date:** 2026-11-15
- **Decision:** `@v128` code sits behind
  `#cfg(any(target="native", target="wasm"))`, in a package of its own next
  to the plain reference, using operations native lowers to few
  instructions.
- **Reason:** toolchain and measured. On JS, `@v128` falls back to code
  some 300 times slower than a plain loop; Wasm GC cannot load sixteen
  bytes from an array at once. Adler-32 written with `extmul` and
  `extadd_pairwise` ran 1.7 times as long on x86 as with widening and
  `i32x4_dot_i16x8_s`. `moon prove` refuses SIMD operations, so the proved
  reference stays as it is. `@v128` is experimental, so each fast package
  silences the alert for itself only.
- **Reopen when:** JS or Wasm GC gain a fast `@v128`, or `@v128` changes.

## No carry-less multiplication for CRC-32

- **Date:** 2026-11-15
- **Decision:** CRC-32 (gzip, PNG) stays a slice-by-8 loop without index
  checks; no PCLMULQDQ.
- **Reason:** toolchain. Neither `@v128` nor Wasm SIMD has the
  instruction, so it would take the repository's first C stub, on native
  only, built with x86's `-mpclmul`, with its own CPU check, a fallback,
  and another path for arm64. The CRC is about 4% of decoding PNG's
  benchmark image.
- **Reopen when:** `@v128` or Wasm gains carry-less multiplication.

## No margin after the Zstandard decoder's ring

- **Date:** 2026-11-15
- **Decision:** no slack after the ring for match copies to write eight
  bytes at a time past their end.
- **Reason:** contract. It would add to `memory_usage` and the bounds in
  RESOURCE_BOUNDS.md; the decoder copies that way only where the ring
  already has the room.
- **Reopen when:** never on its own; only with a change of the bounds.

## The Zstandard decoder's ring is not sized from the content size

- **Date:** 2026-11-15
- **Decision:** the ring grows with the output.
- **Reason:** contract. Sizing it from the frame header would allocate
  what a header claims before any output proves it (bench/README.md,
  "Headers that claim a size").
- **Reopen when:** never.

## No SIMD Adler-32 in the zlib encoder

- **Date:** 2026-11-15
- **Decision:** the zlib encoder keeps the proved Adler-32.
- **Reason:** measured. The encoder reads a `BytesView`, the SIMD package
  an `ArrayView`, and the checksum is 2.4% of encoding.
- **Reopen when:** the checksum grows to a larger share of encoding.

## No 64-bit bit reader in the Brotli decoder

- **Date:** 2026-11-15
- **Decision:** the three-byte refills stay.
- **Reason:** measured. After them, refilling and reading bits are 1.6%
  and 2.7% of decoding.
- **Reopen when:** a profile shows the bit reader above a few percent.

## No 64-bit bit writer in the DEFLATE encoder; Huffman builder checked

- **Date:** 2026-11-15
- **Decision:** the encoder's bit writer and the shared Huffman builder
  keep their index checks.
- **Reason:** proof and measured. The writer's bound on its output is not
  local to it; the builder, about 3% of encoding, is in a shared package
  whose functions are proved.
- **Reopen when:** the builder's proof can carry unchecked accesses.

## Encoders keep their output

- **Date:** 2026-11-15
- **Decision:** speed work does not change an encoder's bytes: no
  one-slot hash table or five-byte hashes in the Brotli encoder, no skipped
  literal runs, no other lazy matching limits, and no faster DEFLATE
  levels in place of the libdeflate-identical ones.
- **Reason:** output. The SHA-256 checks and the compression ratio tables
  hold every encoder's output byte for byte.
- **Reopen when:** a new level or `Strategy` is added that does not promise
  libdeflate's bytes; levels 1 to 9 keep theirs.

## No `extern "js"` typed arrays on JS

- **Date:** 2026-11-14, again 2026-11-20
- **Decision:** no `Uint8Array.copyWithin` or `set` block copies, and no
  `Uint32Array` for the Brotli encoder's q9 hash table (55.3 → 30.8 ms on
  JS).
- **Reason:** toolchain. On 2026-11-14 the repository had no
  `extern "js"`, and `parts/blit`'s forward loop without index checks was
  enough. The hash table depends on how the JS backend represents arrays,
  which MoonBit does not specify. With moonc 0.10.21, `FixedArray[Byte]` is
  a `Uint8Array`, but `FixedArray[UInt]` is a plain `Array` holding `UInt`
  as signed numbers, so a `Uint32Array` in its place reads back values of
  2^31 and above (positions past 2 GiB) that `==` no longer matches; only
  the subtractions the hasher does happen to agree.
- **Reopen when:** the JS backend gives numeric `FixedArray`s a typed
  representation or documents the one it uses (moonbit-docs#646, #1378).

## No LLVM backend

- **Date:** 2026-11-19
- **Decision:** `supported_targets` does not list `llvm`.
- **Reason:** toolchain and measured. The backend is off in the stable
  toolchain; on nightly, zstd's nested value types did not compile, and
  the compressors ran 23 to 35% slower than native.
- **Reopen when:** the stable toolchain enables it. In `#cfg`, `llvm` is
  true together with `native`, so the fast paths would apply as they are.

## Speed work of the 2026-11-19 audit left out

- **Date:** 2026-11-19 to 2026-11-20
- **Decision:** the changes below were tried and not made. The audit's
  rule: a change that made any target more than 2% slower in any benchmark
  was dropped, or kept only where it did not.
- **Reason:** measured.

| Module | Change | Gain seen | Slower |
|---|---|---|---|
| parts/blit | `bytes` copying fewer than 16 bytes with a loop | — | Brotli 16-byte decode +5.5% native, zstd 1-byte decode +16.5% Wasm |
| deflate | no decode attempt on a step that cannot progress (inside the inflater) | — | zlib 1-byte decode +6.2% Wasm |
| deflate | zlib and gzip do not call the inflater again after it used all its input and asked for more | 1,000 empty calls −75 to −88% | gzip 1-byte decode +3.4% JS, deflate 16-byte encode +2.7% Wasm |
| deflate | a fast path for Deflate64, like `go_fast` | Deflate64 decode −54 to −69% on every target | DEFLATE whole-text decode +2.9 to +5.7% native |
| deflate | the parser's updates without index checks | — | level-1 text encode +25% Wasm |
| brotli | hustcer/fbr's single-literal-tree shortcut | none measurable | — |
| zstd | the `Dfast` helpers written out | — | text and 16-byte encode +3.8%, +5.4% Wasm GC (five runs) |
| lzw | the code width kept per width change | — | 1-byte decode +3.8% Wasm |
| lzw | the encoder's `taken` and `written` counted in Int32 per step | — | 1-byte encode +6.0% Wasm GC, +6.8% Wasm |
| lz4 | the encoder's `taken` counted in Int32 per step | — | 1-byte encode +3.6% Wasm GC (five runs) |

- **Reopen when:** a new toolchain changes what the backends compile
  these to; rerun the same A/B.

## Speed work of the 2026-11-19 audit kept on some targets only

- **Date:** 2026-11-19 to 2026-11-20
- **Decision:** these changes sit behind `#cfg` for the targets where they
  paid; the other targets keep the earlier code. Each `#cfg` says why at
  the code.
- **Reason:** measured.

| Module | Change | Kept on | Not on, because |
|---|---|---|---|
| parts/copy16 | two word moves | native, Wasm | Wasm GC slower with word copies (block copy there); JS a byte loop |
| lz4 | copy16 for short sequences | native, Wasm | JS and Wasm GC faster on the old paths |
| lz4 | XXH32 without helper calls | native, Wasm, Wasm GC | JS faster on the old code |
| lz4 | the encoder hashing each block from its own buffer | native, Wasm, Wasm GC | JS faster hashing per step |
| brotli | the slow decode path written out, command tables unchecked | Wasm | 1-byte q4 decode +2.4% native |
| brotli | q10/11 command helpers written out | native, Wasm, JS | q11 147 → 151.5 ms Wasm GC (five runs) |
| zstd | `execute`'s window copies written out | native, Wasm | large-binary step decode +4.8% Wasm GC |
| zstd | `CTable::encode` without index checks | native, Wasm, JS | large-binary level-22 encode +2.8% Wasm GC |
| crc | both reflections skipped when `reflect_in == reflect_out` | Wasm, Wasm GC, JS | whole CRC-16 +17.5% native |
| crc | a 32-bit table and register for widths up to 32 | Wasm, JS | CRC-32/BZIP2 whole +4.0% native, 1-byte +5.9% Wasm GC |
| lzw | `fast_codes` not entered with fewer than 3 bytes left | Wasm, Wasm GC, JS | whole TIFF binary decode +3.1% native |
| lzw | `fast_codes`' table without index checks | Wasm | +6% native (cycles) |

- **Reopen when:** a new toolchain changes what the backends compile
  these to; rerun the same A/B.
