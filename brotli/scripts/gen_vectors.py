#!/usr/bin/env python3
"""Generates src/vectors_wbtest.mbt: the decoder's test vectors.

Each vector is a compressed stream (base64) with the length and SHA-256 of
the bytes it must decode to. Two sources:
- a subset of google/brotli's tests/testdata at a pinned commit, compressed
  files only (their originals are represented by length and SHA-256);
- streams made here with the `brotli` Python module (tested with 1.2.0) from
  deterministic inputs, for what the subset lacks: a 16 MiB window with a
  distance past 4 MiB, the smallest window (also with uncompressed
  meta-blocks), every encoder quality, and
  dictionary words under many transforms.

Usage: scripts/gen_vectors.py [GOOGLE_TESTDATA_DIR]
Without an argument the google files are downloaded from the pinned commit.
Requires the `brotli` Python module. Run `moon fmt` afterwards.
"""

import base64
import hashlib
import random
import subprocess
import sys
import urllib.request
from pathlib import Path

import brotli

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_static_data  # noqa: E402

BROTLI_COMMIT = gen_static_data.BROTLI_COMMIT
RAW = f"https://raw.githubusercontent.com/google/brotli/{BROTLI_COMMIT}/tests/testdata/"

# (original, compressed) file names from google/brotli's tests/testdata.
GOOGLE = [
    ("empty", "empty.compressed"),
    *[("empty", f"empty.compressed.{i:02}") for i in range(18)],
    ("x", "x.compressed"),
    *[("x", f"x.compressed.{i:02}") for i in range(4)],
    ("10x10y", "10x10y.compressed"),
    ("64x", "64x.compressed"),
    ("xyzzy", "xyzzy.compressed"),
    ("quickfox", "quickfox.compressed"),
    ("quickfox_repeated", "quickfox_repeated.compressed"),
    ("ukkonooa", "ukkonooa.compressed"),
    ("monkey", "monkey.compressed"),
    ("cp852-utf8", "cp852-utf8.compressed"),
    ("cp1251-utf16le", "cp1251-utf16le.compressed"),
    ("backward65536", "backward65536.compressed"),
    ("zeros", "zeros.compressed"),
    ("zerosukkanooa", "zerosukkanooa.compressed"),
    ("random_org_10k.bin", "random_org_10k.bin.compressed"),
    ("compressed_file", "compressed_file.compressed"),
    ("compressed_repeated", "compressed_repeated.compressed"),
    ("alice29.txt", "alice29.txt.compressed"),
]


def google_file(source: Path | None, name: str) -> bytes:
    if source is not None:
        return (source / name).read_bytes()
    with urllib.request.urlopen(RAW + name) as response:
        return response.read()


def generated(alice: bytes) -> list[tuple[str, bytes, bytes]]:
    rng = random.Random(7932)
    out = []
    # A 3000-byte block repeated 5 MiB later: only a 16 MiB window reaches it.
    block = bytes(rng.randrange(256) for _ in range(3000))
    filler = bytes((i * 7) & 0xFF for i in range(1 << 22)) + bytes(1 << 20)
    data = block + filler + block
    out.append(("gen/window24_far", brotli.compress(data, quality=11, lgwin=24), data))
    # The smallest window: distances wrap a 1 KiB ring.
    data = alice[:40000]
    out.append(("gen/window10", brotli.compress(data, quality=11, lgwin=10), data))
    # Random bytes under a 1 KiB window: uncompressed meta-blocks longer
    # than the window.
    data = bytes(rng.randrange(256) for _ in range(5000))
    out.append(("gen/random_window10", brotli.compress(data, quality=5, lgwin=10), data))
    # Every quality on mixed text and binary.
    data = alice[50000:56000] + bytes((i * i) & 0xFF for i in range(3000)) + alice[:2000]
    for q in range(12):
        out.append((f"gen/quality{q}", brotli.compress(data, quality=q, lgwin=18), data))
    # Signed 16-bit samples, a candidate for the signed context mode.
    samples = b"".join(
        int(3000 * ((i % 64) - 32) / 32 + rng.randrange(-40, 40)).to_bytes(2, "little", signed=True)
        for i in range(8000)
    )
    out.append(("gen/samples16", brotli.compress(samples, quality=11, lgwin=20), samples))
    # Dictionary words under many transforms.
    dictionary = gen_static_data.fetch(gen_static_data.DICTIONARY_URL)
    rfc = gen_static_data.fetch(gen_static_data.RFC_URL).decode()
    transforms = gen_static_data.transforms(rfc)
    data = b"".join(transformed_word(dictionary, transforms, rng) for _ in range(3000))
    out.append(("gen/transforms", brotli.compress(data, quality=11, lgwin=22), data))
    return out


def transformed_word(dictionary: bytes, transforms, rng: random.Random) -> bytes:
    bits = [0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5]
    offsets = [0] * 25
    for length in range(4, 24):
        offsets[length + 1] = offsets[length] + (length << bits[length])
    length = rng.randrange(4, 25)
    index = rng.randrange(1 << bits[length])
    word = bytearray(dictionary[offsets[length] + index * length :][:length])
    prefix, kind, suffix = transforms[rng.randrange(len(transforms))]
    if 1 <= kind <= 9:
        word = word[: max(0, length - kind)]
    elif kind >= 12:
        word = word[kind - 11 :]
    if kind in (10, 11):
        i = 0
        while i < len(word):
            c = word[i]
            step = 1 if c < 192 else 2 if c < 224 else 3
            if c < 192:
                if 97 <= c <= 122:
                    word[i] ^= 32
            elif c < 224:
                if i + 1 < len(word):
                    word[i + 1] ^= 32
            elif i + 2 < len(word):
                word[i + 2] ^= 5
            i += step
            if kind == 10:
                break
    return prefix + bytes(word) + suffix


def literal(text: str) -> str:
    lines = [text[i : i + 76] for i in range(0, len(text), 76)] or [""]
    return "(\n      " + "\n      ".join("#|" + line for line in lines) + "\n    )"


def main() -> None:
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    vectors = []
    for original, compressed in GOOGLE:
        vectors.append(
            (compressed, google_file(source, compressed), google_file(source, original))
        )
    vectors += generated(google_file(source, "alice29.txt"))
    out = [
        "// Generated by scripts/gen_vectors.py, DON'T EDIT IT.",
        f"// google/brotli tests/testdata at {BROTLI_COMMIT}, and streams",
        f"// made with the brotli Python module {brotli.version}.",
        "",
        "///|",
        "let vectors : Array[Vector] = [",
    ]
    for name, compressed, original in vectors:
        if brotli.decompress(compressed) != original:
            raise SystemExit(f"{name}: does not decode to its original")
        out += [
            "  {",
            f'    name: "{name}",',
            f"    compressed: {literal(base64.b64encode(compressed).decode())},",
            f"    size: {len(original)},",
            f'    sha256: "{hashlib.sha256(original).hexdigest()}",',
            "  },",
        ]
    out += ["]", ""]
    target = Path(__file__).resolve().parent.parent / "src" / "vectors_wbtest.mbt"
    target.write_text("\n".join(out))
    subprocess.run(["moon", "fmt"], cwd=target.parent.parent, check=True)
    print(f"wrote {target}: {len(vectors)} vectors")


if __name__ == "__main__":
    main()
