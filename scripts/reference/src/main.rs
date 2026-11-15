//! Reads lines of "<format>\t<base64 data>[\t<base64 dictionary>]" on stdin
//! and prints one line for each. Decoding formats print "<length> <sha256
//! hex>" of what the reference decodes, or "error <why>": raw (DEFLATE) and
//! zlib with miniz_oxide, snappy-raw and snappy-frame with snap, lz4-frame
//! and lz4-block with lz4_flex. Encoding formats print the base64 of what the
//! reference writes: snappy-raw-encode and snappy-frame-encode with snap;
//! with lz4 1.10.0's C library (lz4-sys), lz4f-encode:<options> (a frame;
//! options "bs=<4..7>,indep=<0|1>,cc=<0|1>,bc=<0|1>,cs=<0|1>,level=<n>,
//! dictid=<n>", the dictionary when given), lz4-block-encode:<acceleration>
//! (LZ4_compress_fast, or after LZ4_loadDict with a dictionary) and
//! lz4-legacy-encode (lz4 -l's legacy frame).

use base64::Engine;
use sha2::{Digest, Sha256};
use std::io::{self, BufRead, Read, Write};

mod lz4c {
    //! The parts of lz4's C library (compiled by lz4-sys) that lz4-sys does
    //! not declare.
    use lz4_sys::{LZ4FCompressionContext, LZ4FPreferences, LZ4StreamEncode};
    use std::os::raw::{c_char, c_int, c_void};
    extern "C" {
        pub fn LZ4F_createCDict(dict: *const c_void, dict_size: usize) -> *mut c_void;
        pub fn LZ4F_freeCDict(cdict: *mut c_void);
        // The CDict, unlike LZ4F_compressBegin_usingDict, serves every
        // block of a frame of independent blocks (lz4frame.c says so).
        pub fn LZ4F_compressBegin_usingCDict(
            ctx: LZ4FCompressionContext,
            dst: *mut c_void,
            dst_capacity: usize,
            cdict: *const c_void,
            prefs: *const LZ4FPreferences,
        ) -> usize;
        pub fn LZ4_loadDict(stream: *mut LZ4StreamEncode, dict: *const c_char, size: c_int) -> c_int;
        pub fn LZ4_compress_fast_continue(
            stream: *mut LZ4StreamEncode,
            src: *const c_char,
            dst: *mut c_char,
            src_size: c_int,
            dst_capacity: c_int,
            acceleration: c_int,
        ) -> c_int;
    }
}

/// A frame from lz4's library, with the options of an lz4f-encode line.
fn lz4f_encode(options: &str, input: &[u8], dict: &[u8]) -> Vec<u8> {
    use lz4_sys::*;
    let mut prefs = LZ4FPreferences {
        frame_info: LZ4FFrameInfo {
            block_size_id: BlockSize::Max64KB,
            block_mode: BlockMode::Linked,
            content_checksum_flag: ContentChecksum::NoChecksum,
            frame_type: FrameType::Frame,
            content_size: 0,
            dict_id: 0,
            block_checksum_flag: BlockChecksum::NoBlockChecksum,
        },
        compression_level: 0,
        auto_flush: 0,
        favor_dec_speed: 0,
        reserved: [0; 3],
    };
    for option in options.split(',') {
        let (key, value) = option.split_once('=').expect("key=value");
        let n: i64 = value.parse().expect("a number");
        match key {
            "bs" => {
                prefs.frame_info.block_size_id = match n {
                    4 => BlockSize::Max64KB,
                    5 => BlockSize::Max256KB,
                    6 => BlockSize::Max1MB,
                    7 => BlockSize::Max4MB,
                    _ => panic!("block size {n}"),
                }
            }
            "indep" => {
                prefs.frame_info.block_mode = if n == 1 { BlockMode::Independent } else { BlockMode::Linked }
            }
            "cc" => {
                prefs.frame_info.content_checksum_flag =
                    if n == 1 { ContentChecksum::ChecksumEnabled } else { ContentChecksum::NoChecksum }
            }
            "bc" => {
                prefs.frame_info.block_checksum_flag =
                    if n == 1 { BlockChecksum::BlockChecksumEnabled } else { BlockChecksum::NoBlockChecksum }
            }
            "cs" => prefs.frame_info.content_size = if n == 1 { input.len() as u64 } else { 0 },
            // Negative levels are lz4's fast modes: acceleration 1 - level.
            "level" => prefs.compression_level = n as i32 as u32,
            "dictid" => prefs.frame_info.dict_id = n as u32,
            _ => panic!("unknown option {key}"),
        }
    }
    unsafe {
        let mut ctx = LZ4FCompressionContext(std::ptr::null_mut());
        assert_eq!(LZ4F_isError(LZ4F_createCompressionContext(&mut ctx, LZ4F_VERSION)), 0);
        let capacity = LZ4F_compressBound(input.len(), &prefs) + 64;
        let mut out = vec![0u8; capacity];
        let cdict = if dict.is_empty() {
            std::ptr::null_mut()
        } else {
            lz4c::LZ4F_createCDict(dict.as_ptr() as *const _, dict.len())
        };
        let mut pos = if dict.is_empty() {
            LZ4F_compressBegin(ctx, out.as_mut_ptr(), capacity, &prefs)
        } else {
            lz4c::LZ4F_compressBegin_usingCDict(ctx, out.as_mut_ptr() as *mut _, capacity, cdict, &prefs)
        };
        assert_eq!(LZ4F_isError(pos), 0, "LZ4F_compressBegin");
        let n = LZ4F_compressUpdate(
            ctx,
            out.as_mut_ptr().add(pos),
            capacity - pos,
            input.as_ptr(),
            input.len(),
            std::ptr::null(),
        );
        assert_eq!(LZ4F_isError(n), 0, "LZ4F_compressUpdate");
        pos += n;
        let n = LZ4F_compressEnd(ctx, out.as_mut_ptr().add(pos), capacity - pos, std::ptr::null());
        assert_eq!(LZ4F_isError(n), 0, "LZ4F_compressEnd");
        pos += n;
        LZ4F_freeCompressionContext(ctx);
        if !cdict.is_null() {
            lz4c::LZ4F_freeCDict(cdict);
        }
        out.truncate(pos);
        out
    }
}

/// A block from LZ4_compress_fast, or after LZ4_loadDict with a dictionary.
fn lz4_block_encode(acceleration: i32, input: &[u8], dict: &[u8]) -> Vec<u8> {
    use lz4_sys::*;
    unsafe {
        let capacity = LZ4_compressBound(input.len() as i32);
        let mut out = vec![0u8; capacity as usize];
        let n = if dict.is_empty() {
            LZ4_compress_fast(
                input.as_ptr() as *const _,
                out.as_mut_ptr() as *mut _,
                input.len() as i32,
                capacity,
                acceleration,
            )
        } else {
            let stream = LZ4_createStream();
            lz4c::LZ4_loadDict(stream, dict.as_ptr() as *const _, dict.len() as i32);
            let n = lz4c::LZ4_compress_fast_continue(
                stream,
                input.as_ptr() as *const _,
                out.as_mut_ptr() as *mut _,
                input.len() as i32,
                capacity,
                acceleration,
            );
            LZ4_freeStream(stream);
            n
        };
        assert!(n > 0 || input.is_empty(), "LZ4_compress_fast");
        out.truncate(n as usize);
        out
    }
}

/// lz4 -l's legacy frame: the magic number, then each 8 MiB of the input as
/// a block, its compressed size first.
fn lz4_legacy_encode(input: &[u8]) -> Vec<u8> {
    let mut out = 0x184C2102u32.to_le_bytes().to_vec();
    for chunk in input.chunks(8 << 20) {
        let block = lz4_block_encode(1, chunk, &[]);
        out.extend_from_slice(&(block.len() as u32).to_le_bytes());
        out.extend_from_slice(&block);
    }
    out
}

fn main() {
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout());
    for line in stdin.lock().lines() {
        let line = line.expect("stdin");
        let mut fields = line.split('\t');
        let format = fields.next().expect("format");
        let b64 = base64::engine::general_purpose::STANDARD;
        let input = b64.decode(fields.next().expect("data")).expect("base64");
        let dict = fields.next().map(|d| b64.decode(d).expect("base64")).unwrap_or_default();
        if let Some(encoded) = match format.split_once(':') {
            Some(("lz4f-encode", options)) => Some(lz4f_encode(options, &input, &dict)),
            Some(("lz4-block-encode", acceleration)) => {
                Some(lz4_block_encode(acceleration.parse().expect("acceleration"), &input, &dict))
            }
            None if format == "lz4-legacy-encode" => Some(lz4_legacy_encode(&input)),
            _ => None,
        } {
            writeln!(out, "{}", b64.encode(&encoded)).unwrap();
            continue;
        }
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
            "lz4-frame" => {
                let mut out = Vec::new();
                lz4_flex::frame::FrameDecoder::new(&input[..])
                    .read_to_end(&mut out)
                    .map(|_| out)
                    .map_err(|e| e.to_string())
            }
            "lz4-block" => {
                let capacity = (input.len() * 255 + 64).min(1 << 28);
                lz4_flex::block::decompress(&input, capacity).map_err(|e| e.to_string())
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
