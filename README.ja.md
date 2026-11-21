# codecs.mbt

純粋な MoonBit で書いた、ストリーミングのコーデック集です。Native・JS・Wasm・Wasm GC で動き、Zstandard・Brotli・DEFLATE/zlib/gzip・LZ4・Snappy・LZW・PNG・CRC を扱います。入力はどんな大きさの断片で届いてもよく、出力はどんな大きさの領域にも書け、メモリは呼び出し側が決めた上限に収まります。各モジュールは [mooncakes.io](https://mooncakes.io) に個別に公開していて、README・版・変更履歴もそれぞれにあります。

[English](README.md)

## どのモジュールを使うか

| したいこと | 足すモジュール |
|---|---|
| HTTP の内容のコーディング(`gzip`・`deflate`・`br`・`zstd`)をデコード・エンコードする | [`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate)、[`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli)、[`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd)。[`gaato/mttp`](https://github.com/gaato/mttp) は三つとも組み込み済み |
| `.gz`・`.zst`・`.br`・`.lz4`・`.sz`・`.Z` のファイルを読み書きする | `gaato/deflate`、`gaato/zstd`、`gaato/brotli`、[`gaato/lz4`](https://mooncakes.io/docs/gaato/lz4)、[`gaato/snappy`](https://mooncakes.io/docs/gaato/snappy)、[`gaato/lzw`](https://mooncakes.io/docs/gaato/lzw) |
| LevelDB や Parquet の Snappy を読み書きする | `gaato/snappy`(raw 形式) |
| GIF・TIFF・PDF の読み込みの中で LZW をデコードする | `gaato/lzw` |
| PNG や APNG を RGBA で、または 1 行ずつ読み込む | [`gaato/png`](https://mooncakes.io/docs/gaato/png) |
| `CRC-32C` や `CRC-16/MODBUS` のような名前で指定した CRC を計算・検証する | [`gaato/crc`](https://mooncakes.io/docs/gaato/crc) |
| どのバイト列の形式でも回せるループを一度だけ書く | [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes) |
| どの画像デコーダーでも回せるループを一度だけ書く | [`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image) |
| どのコーデックのエラーも同じように扱う | [`gaato/codec`](https://mooncakes.io/docs/gaato/codec) |
| ZIP アーカイブを読み書きする | [archive.mbt](https://github.com/gaato/archive.mbt) の [`gaato/zip`](https://mooncakes.io/docs/gaato/zip) |

| モジュール | 中身 | ディレクトリ |
|---|---|---|
| `gaato/codec` | すべてのコーデックが報告に使うエラーの種類と上限 | [`codec/`](codec/) |
| `gaato/codec_bytes` | バイト列のコーデックの契約 | [`codec_bytes/`](codec_bytes/) |
| `gaato/zstd` | Zstandard(RFC 8878)のデコーダーとエンコーダー | [`zstd/`](zstd/) |
| `gaato/brotli` | Brotli(RFC 7932)のデコーダーとエンコーダー | [`brotli/`](brotli/) |
| `gaato/deflate` | DEFLATE(RFC 1951)・zlib(RFC 1950)・gzip(RFC 1952)のデコーダーとエンコーダー、Deflate64 のデコーダー | [`deflate/`](deflate/) |
| `gaato/snappy` | Snappy の raw 形式(一括)とフレーミング形式(ストリーム)のデコーダーとエンコーダー | [`snappy/`](snappy/) |
| `gaato/lz4` | LZ4 のフレーム(ストリーム)とブロック。エンコーダーは lz4 と同じバイトを書く | [`lz4/`](lz4/) |
| `gaato/lzw` | GIF・TIFF・PDF・Unix compress(.Z)の LZW のデコーダーとエンコーダー | [`lzw/`](lzw/) |
| `gaato/codec_image` | 画像デコーダーの契約 | [`codec_image/`](codec_image/) |
| `gaato/png` | PNG と APNG のデコーダー | [`png/`](png/) |
| `gaato/crc` | 64 ビットまでの CRC をパラメーターか名前で。断片をまたいで結合もできる | [`crc/`](crc/) |

コーデックは種類ごとに一つの契約を守ります。契約は [CONTRACT.md](CONTRACT.md) にあります。リポジトリの構成は [ARCHITECTURE.md](ARCHITECTURE.md) に、なぜこう作ったか、何を試して見送ったかは [docs/decisions.md](docs/decisions.md) にあります。機能・適合性・メモリ・速さの [ほかの MoonBit 実装との比較](bench/README.md) もあります。

## TODO

- [ ] 画像
  - [ ] PNG のエンコード
  - [ ] GIF のデコード
  - [ ] JPEG のデコード
  - [ ] 可逆 WebP
  - [ ] QOI
- [ ] xz
  - [ ] デコード
  - [ ] エンコード
- [ ] bzip2
  - [ ] デコード
  - [ ] エンコード

tar は [archive.mbt](https://github.com/gaato/archive.mbt) に置き、ここの xz の上で扱います。不具合や要望は [Issues](https://github.com/gaato/codecs.mbt/issues) へどうぞ。

## 開発

ツールチェーン、ゲートの動かし方、CI の構成は英語版の [Development](README.md#development) にあります。

## ライセンス

Apache-2.0 です。テストデータや表のライセンスは各モジュールを参照してください。
