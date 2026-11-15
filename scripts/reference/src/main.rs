//! Reads lines of "<format>\t<base64 stream>" on stdin and prints, for each,
//! "<length> <sha256 hex>" of what the reference decodes, or "error <why>".
//! Formats: raw (DEFLATE) and zlib, decoded with miniz_oxide.

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
        let decoded = match format {
            "raw" => miniz_oxide::inflate::decompress_to_vec(&input),
            "zlib" => miniz_oxide::inflate::decompress_to_vec_zlib(&input),
            other => panic!("unknown format {other}"),
        };
        match decoded {
            Ok(bytes) => {
                let digest = Sha256::digest(&bytes);
                let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
                writeln!(out, "{} {}", bytes.len(), hex).unwrap();
            }
            Err(err) => writeln!(out, "error {err:?}").unwrap(),
        }
    }
}
