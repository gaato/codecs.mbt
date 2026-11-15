//! Reads lines of "<format>\t<base64 data>" on stdin and prints one line for
//! each. Decoding formats print "<length> <sha256 hex>" of what the reference
//! decodes, or "error <why>": raw (DEFLATE) and zlib with miniz_oxide,
//! snappy-raw and snappy-frame with snap. Encoding formats print the base64
//! of what the reference writes: snappy-raw-encode and snappy-frame-encode.

use base64::Engine;
use sha2::{Digest, Sha256};
use std::io::{self, BufRead, Write};

fn main() {
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout());
    for line in stdin.lock().lines() {
        let line = line.expect("stdin");
        let (format, data) = line.split_once('\t').expect("format\\tdata");
        let input = base64::engine::general_purpose::STANDARD
            .decode(data)
            .expect("base64");
        let decoded: Result<Vec<u8>, String> = match format {
            "raw" => miniz_oxide::inflate::decompress_to_vec(&input).map_err(|e| format!("{e:?}")),
            "zlib" => miniz_oxide::inflate::decompress_to_vec_zlib(&input).map_err(|e| format!("{e:?}")),
            "snappy-raw" => snap::raw::Decoder::new().decompress_vec(&input).map_err(|e| e.to_string()),
            "snappy-frame" => {
                let mut out = Vec::new();
                std::io::copy(&mut snap::read::FrameDecoder::new(&input[..]), &mut out)
                    .map(|_| out)
                    .map_err(|e| e.to_string())
            }
            "snappy-raw-encode" | "snappy-frame-encode" => {
                let encoded = if format == "snappy-raw-encode" {
                    snap::raw::Encoder::new().compress_vec(&input).expect("snap compresses")
                } else {
                    let mut w = snap::write::FrameEncoder::new(Vec::new());
                    w.write_all(&input).expect("snap writes");
                    w.into_inner().expect("snap finishes")
                };
                writeln!(out, "{}", base64::engine::general_purpose::STANDARD.encode(&encoded)).unwrap();
                continue;
            }
            other => panic!("unknown format {other}"),
        };
        match decoded {
            Ok(bytes) => {
                let digest = Sha256::digest(&bytes);
                let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
                writeln!(out, "{} {}", bytes.len(), hex).unwrap();
            }
            Err(err) => writeln!(out, "error {err}").unwrap(),
        }
    }
}
