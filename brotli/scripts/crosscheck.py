#!/usr/bin/env python3
"""Decodes the encoder's streams with the reference decoder.

Runs src/internal/crosscheck, which prints one line per stream: a name, the
length and SHA-256 of the input so far, and the base64 of the stream so far.
Each stream must decode, with google/brotli's decoder, to exactly that input:
a whole stream through brotli.decompress, a stream cut after a flush through
a Decompressor that must give out everything without being told the end.

Requires the `brotli` Python module (google/brotli's binding).
Usage: scripts/crosscheck.py [--target native|js|wasm|wasm-gc] [--compare]
  --compare  also print the sizes from gzip -6 and google/brotli at
             qualities 1, 4 and 11 (same window), for the ratio record.
Exit status: 0 = every stream decodes, 1 = one does not, 2 = setup failure.
"""

import argparse
import base64
import hashlib
import os
import subprocess
import sys
import zlib

try:
    import brotli
except ImportError:
    print("crosscheck.py needs the brotli Python module", file=sys.stderr)
    sys.exit(2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default="native")
    parser.add_argument("--compare", action="store_true")
    args = parser.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ)
    env.setdefault("MOON_CC", "cc")
    run = subprocess.run(
        ["moon", "run", "--release", "--target", args.target, "src/internal/crosscheck"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        print(run.stderr, file=sys.stderr)
        return 2
    failures = 0
    checked = 0
    for line in run.stdout.splitlines():
        name, size, digest, stream = line.split("\t")
        data = base64.b64decode(stream)
        try:
            if " flush " in name:
                # process() hands out at most about 32 KiB per call.
                decompressor = brotli.Decompressor()
                decoded = decompressor.process(data)
                while more := decompressor.process(b""):
                    decoded += more
            else:
                decoded = brotli.decompress(data)
        except brotli.error as err:
            print(f"FAIL {name}: {err}")
            failures += 1
            continue
        if len(decoded) != int(size) or hashlib.sha256(decoded).hexdigest() != digest:
            print(f"FAIL {name}: decodes to {len(decoded)} different bytes")
            failures += 1
            continue
        checked += 1
        if " flush " not in name:
            ratio = len(data) / max(int(size), 1)
            print(f"ok   {name}: {size} -> {len(data)} bytes ({ratio:.3f})")
            if args.compare and decoded:
                lgwin = int(name.split(" w")[1].split()[0])
                gzip = zlib.compressobj(6, zlib.DEFLATED, 31)
                sizes = [len(gzip.compress(decoded) + gzip.flush())] + [
                    len(brotli.compress(decoded, quality=q, lgwin=max(lgwin, 10)))
                    for q in (1, 4, 11)
                ]
                print("       gzip -6 {}, brotli q1 {}, q4 {}, q11 {}".format(*sizes))
    if checked == 0:
        print("no streams checked", file=sys.stderr)
        return 2
    print(f"crosscheck: {checked} streams decode with the reference decoder"
          + (f", {failures} FAILED" if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
