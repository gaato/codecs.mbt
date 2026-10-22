# Compression levels and ratio

How the encoders of `gaato/deflate` (raw DEFLATE, zlib and gzip share one)
choose their output, and what they come to against zlib. The module
[README](../src/overview.mbt.md) says what a caller needs; this is the
background, with measurements that hold for the versions named.

## The levels

The levels are libdeflate's: 0 stores the input; 1 finds matches in a hash
table; 2 to 4 take the longest match at each position, and 5 to 9 look one or
two positions ahead for a better one, over hash chains. Each block takes the
fixed Huffman code, a dynamic one or no code (stored), whichever is smallest,
and ends where the data changes (libdeflate's block splitting) or after
64 KiB. Inputs of a few dozen bytes or less are stored, as libdeflate stores
them.

With the same input, no dictionary and no flush, the streams are the bytes
that libdeflate 1.24 writes when its blocks are limited to 64 KiB;
`src/encode_wbtest.mbt` pins their SHA-256 at each level. They decode with
zlib and the `gzip` command, whole and cut after every flush:
[`scripts/crosscheck.mbtx`](../scripts/crosscheck.mbtx) checks that, and CI
runs it. The same input gives the same bytes on every target, however it is
split.

libdeflate's levels 10 to 12, whose near-optimal parsing comes out about 3 %
smaller than level 9 at several times the time, are not implemented.

## Ratio against zlib

Sizes in bytes of raw DEFLATE streams for six files of the [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia), against zlib 1.3.2.1 at the same levels:

| File | Size | here -1 | zlib -1 | here -6 | zlib -6 | here -9 | zlib -9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10,192,446 | 4,217,525 | 4,585,612 | 3,864,185 | 3,871,628 | 3,816,762 | 3,854,729 |
| mozilla | 51,220,480 | 20,192,961 | 20,577,220 | 18,807,653 | 19,089,118 | 18,716,681 | 19,044,390 |
| nci | 33,553,445 | 3,837,577 | 4,624,591 | 3,102,963 | 3,200,182 | 2,935,668 | 2,987,995 |
| ooffice | 6,152,192 | 3,275,124 | 3,290,526 | 3,073,999 | 3,097,288 | 3,068,726 | 3,092,920 |
| samba | 21,606,400 | 5,866,517 | 6,329,449 | 5,338,862 | 5,451,399 | 5,272,299 | 5,402,704 |
| xml | 5,345,280 | 887,708 | 965,242 | 686,486 | 687,991 | 651,148 | 658,899 |
| total | 128,070,243 | 38,277,412 | 40,372,640 | 34,874,148 | 35,397,606 | 34,461,284 | 35,041,637 |

Level 1 compresses about 5 % more than zlib's level 1, and levels 6 and 9 about 1.5 % more than zlib's: every file comes out smaller, at level 6 by 0.2 % (dickens, xml) to 3.0 % (nci). On the [Canterbury corpus](https://corpus.canterbury.ac.nz/) the eleven files come to 722,392 bytes at level 6, against zlib's 730,888. Random bytes go into stored blocks, 5 bytes more for each 65,535; a long run of one byte costs a few bytes for each 64 KiB block.

To measure the sizes and the speed on a directory of files, from the
repository root:

```sh
moon run deflate/scripts/ratio.mbtx -- DIR
```

See [`scripts/ratio.mbtx`](../scripts/ratio.mbtx) for its options.
