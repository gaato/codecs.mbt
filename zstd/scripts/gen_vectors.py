#!/usr/bin/env python3
"""Generates src/vectors_wbtest.mbt: the decoder's test vectors.

Each vector is a compressed stream (base64) with the length and SHA-256 of
the bytes it must decode to, and the smallest `max_window_bits` that accepts
it. Two sources:
- facebook/zstd's golden decompression files, vendored under
  testdata/upstream (BSD, see NOTICE): frames that decode, and frames that
  must be refused as corrupt;
- streams made here with the `zstandard` Python module from deterministic
  inputs: every kind of block, literals section and table mode the reference
  encoder emits, at many levels and windows, with and without content sizes
  and checksums, several frames in a row and skippable frames between them.

Usage: uv run --no-project --with zstandard==0.25.0 python scripts/gen_vectors.py [--check]
--check regenerates into memory and fails if src/vectors_wbtest.mbt differs.
"""

import base64
import hashlib
import random
import struct
import sys
from pathlib import Path

import zstandard as zstd

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / "testdata" / "upstream"
TARGET = ROOT / "src" / "vectors_wbtest.mbt"
ZSTD_COMMIT = "49cf51799ea051457f57243527aa2058f999f005"

GOLDEN = ["block-128k.zst", "empty-block.zst", "rle-first-block.zst", "zeroSeq_2B.zst"]
GOLDEN_ERRORS = ["off0.bin.zst", "truncated_huff_state.zst", "zeroSeq_extraneous.zst"]

WORDS = (
    "the of and to in is was that for it with as his on be at by had are but "
    "from or have an they which one you were all her she there would their we "
    "him been has when who will no more if out so said what up its about than "
    "into them can only other time new some could these two may first then do "
    "any like my now over such our man me even most made after also did many "
    "before must through back years where much your way well down should "
    "because each just those people how too little state good very make world "
    "still own see men work long get here between both life being under never "
    "zstandard window frame block literal sequence offset match huffman entropy"
).split()


def text(rng: random.Random, n: int) -> bytes:
    out = bytearray()
    while len(out) < n:
        sentence = " ".join(rng.choice(WORDS) for _ in range(rng.randrange(4, 18)))
        out += sentence.capitalize().encode() + rng.choice([b". ", b", ", b".\n", b"; "])
    return bytes(out[:n])


def noise(rng: random.Random, n: int) -> bytes:
    return rng.randbytes(n)


def compress(data: bytes, level: int = 3, checksum: bool = True, size: bool = True, **params) -> bytes:
    p = zstd.ZstdCompressionParameters.from_level(
        level,
        source_size=len(data) if size else 0,
        write_checksum=int(checksum),
        write_content_size=int(size),
        **params,
    )
    c = zstd.ZstdCompressor(compression_params=p)
    if size:
        return c.compress(data)
    obj = c.compressobj()
    return obj.compress(data) + obj.flush()


def flushed(data: bytes, chunk: int, level: int = 3) -> bytes:
    """A frame of unknown size with a block flush every `chunk` bytes."""
    obj = zstd.ZstdCompressor(level=level, write_checksum=True).compressobj()
    out = b""
    for i in range(0, len(data), chunk):
        out += obj.compress(data[i : i + chunk]) + obj.flush(zstd.COMPRESSOBJ_FLUSH_BLOCK)
    return out + obj.flush()


def skippable(magic_low: int, payload: bytes) -> bytes:
    return struct.pack("<II", 0x184D2A50 | magic_low, len(payload)) + payload


def generated() -> list[tuple[str, bytes, bytes]]:
    rng = random.Random(8878)
    out = []

    def add(name: str, compressed: bytes, original: bytes) -> None:
        out.append((f"gen/{name}", compressed, original))

    add("empty", compress(b""), b"")
    add("empty_unknown_size", compress(b"", size=False), b"")
    add("one_byte", compress(b"x"), b"x")
    prose = text(rng, 60_000)
    for level in [-5, 1, 3, 9, 19]:
        add(f"text_level{level}", compress(prose, level=level), prose)
    add("text_level22", compress(prose[:40_000], level=22), prose[:40_000])
    add("text_no_checksum", compress(prose[:30_000], checksum=False), prose[:30_000])
    add("text_unknown_size", compress(prose[:30_000], size=False), prose[:30_000])
    # Content sizes in 1, 2 and 4 bytes.
    for n in [200, 300, 70_000]:
        add(f"text_{n}", compress(prose[:n], level=6), prose[:n])
    # Incompressible bytes: raw blocks.
    data = noise(rng, 40_000)
    add("random", compress(data), data)
    # Runs: RLE blocks and RLE literals.
    data = bytes(1 << 20)
    add("zeros", compress(data, level=1), data)
    data = b"".join(bytes([rng.randrange(256)]) * rng.randrange(1, 300) for _ in range(3000))
    add("runs", compress(data, level=19), data)
    # Text, binary and runs mixed, flushed every few KiB: many small blocks.
    data = b"".join(
        rng.choice([text(rng, 3000), noise(rng, 500), bytes([rng.randrange(256)]) * 2000])
        for _ in range(60)
    )
    add("mixed_flushed", flushed(data, 4096), data)
    add("mixed_level19", compress(data, level=19), data)
    # A 1 KiB window: offsets wrap the smallest ring, blocks are at most 1 KiB.
    data = prose[:40_000]
    add("window10_text", compress(data, level=19, size=False, window_log=10), data)
    data = noise(rng, 5000)
    add("window10_random", compress(data, level=3, size=False, window_log=10), data)
    # A 3000-byte block repeated 5 MiB later: only an 8 MiB window reaches it.
    block = noise(rng, 3000)
    filler = bytes((i * 7) & 0xFF for i in range(1 << 22)) + bytes(1 << 20)
    data = block + filler + block
    add(
        "window23_far",
        compress(data, level=19, size=False, window_log=23, enable_ldm=True),
        data,
    )
    # Large declared windows over little data.
    data = prose[:10_000]
    add("window27_declared", compress(data, size=False, window_log=27), data)
    add("window30_declared", compress(data, size=False, window_log=30), data)
    # Frames in a row, and skippable frames among them.
    a, b = prose[:5000], prose[5000:9000]
    add("two_frames", compress(a) + compress(b, level=19, checksum=False), a + b)
    add(
        "skippable_between",
        compress(a) + skippable(0, b"metadata" * 3) + skippable(15, b"") + compress(b),
        a + b,
    )
    add("skippable_only", skippable(7, noise(rng, 100)), b"")
    add("skippable_first", skippable(1, b"x") + compress(a), a)
    return out


def window_bits(stream: bytes) -> int:
    """The smallest max_window_bits that accepts every frame of `stream`."""
    bits = 10
    pos = 0
    while pos < len(stream):
        (magic,) = struct.unpack_from("<I", stream, pos)
        if magic & 0xFFFFFFF0 == 0x184D2A50:
            (size,) = struct.unpack_from("<I", stream, pos + 4)
            pos += 8 + size
            continue
        params = zstd.get_frame_parameters(stream[pos:])
        window = params.window_size
        while (1 << bits) < window:
            bits += 1
        pos += frame_length(stream, pos)
    return bits


def frame_length(stream: bytes, pos: int) -> int:
    """The length of the zstd frame at `pos`, walking its block headers."""
    descriptor = stream[pos + 4]
    single = descriptor & 0x20
    did = [0, 1, 2, 4][descriptor & 3]
    fcs = [1 if single else 0, 2, 4, 8][descriptor >> 6]
    at = pos + 5 + (0 if single else 1) + did + fcs
    while True:
        header = int.from_bytes(stream[at : at + 3], "little")
        size = 1 if (header >> 1) & 3 == 1 else header >> 3
        at += 3 + size
        if header & 1:
            break
    if descriptor & 0x04:
        at += 4
    return at - pos


def literal(data: bytes) -> str:
    encoded = base64.b64encode(data).decode()
    lines = [encoded[i : i + 76] for i in range(0, len(encoded), 76)] or [""]
    return "(\n      " + "\n      ".join("#|" + line for line in lines) + "\n    )"


def render() -> str:
    vectors = []
    for name in GOLDEN:
        compressed = (UPSTREAM / "golden-decompression" / name).read_bytes()
        original = zstd.ZstdDecompressor().decompressobj(read_across_frames=True).decompress(compressed)
        vectors.append((f"upstream/{name}", compressed, original))
    vectors += generated()
    out = [
        "// Generated by scripts/gen_vectors.py, DON'T EDIT IT.",
        f"// facebook/zstd tests/golden-decompression* at {ZSTD_COMMIT}, and",
        f"// streams made with the zstandard Python module {zstd.__version__}",
        f"// (libzstd {'.'.join(map(str, zstd.ZSTD_VERSION))}).",
        "",
        "///|",
        "let vectors : Array[Vector] = [",
    ]
    for name, compressed, original in vectors:
        decoded = zstd.ZstdDecompressor(max_window_size=1 << 31).decompressobj(read_across_frames=True).decompress(compressed)
        if decoded != original:
            raise SystemExit(f"{name}: does not decode to its original")
        out += [
            "  {",
            f'    name: "{name}",',
            f"    compressed: {literal(compressed)},",
            f"    size: {len(original)},",
            f'    sha256: "{hashlib.sha256(original).hexdigest()}",',
            f"    window_bits: {window_bits(compressed)},",
            "  },",
        ]
    out += [
        "]",
        "",
        "///|",
        "/// Frames the reference decoder refuses as corrupt: names and streams.",
        "let corrupt_vectors : Array[(String, String)] = [",
    ]
    for name in GOLDEN_ERRORS:
        compressed = (UPSTREAM / "golden-decompression-errors" / name).read_bytes()
        try:
            zstd.ZstdDecompressor().decompressobj(read_across_frames=True).decompress(compressed)
        except zstd.ZstdError:
            pass
        else:
            raise SystemExit(f"{name}: decodes, but should not")
        out += [
            "  (",
            f'    "upstream/{name}",',
            "    " + literal(compressed) + ",",
            "  ),",
        ]
    out += ["]", ""]
    return "\n".join(out)


def main() -> None:
    rendered = render()
    if sys.argv[1:] == ["--check"]:
        if TARGET.read_text() != rendered:
            raise SystemExit(f"{TARGET} differs from what gen_vectors.py makes")
        print(f"{TARGET}: up to date")
        return
    TARGET.write_text(rendered)
    print(f"wrote {TARGET}")


if __name__ == "__main__":
    main()
