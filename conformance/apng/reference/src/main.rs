//! For each file named on the command line, prints one line: the file, then
//! `ok`, the image's size and acTL (`frames=<n> plays=<n>`, or `still`), and
//! for each frame `; <x>,<y> <w>x<h> <delay num>/<den> <dispose> <blend>
//! <sha256>` with the values as fcTL stores them (`-` for a default image
//! without one) and the digest of its samples: the frame's rows as the png
//! crate gives them raw, deinterlaced, one byte a sample up to 8 bits and
//! two, big-endian, for 16. Or `error` and the error, after the frames
//! before it.

use sha2::{Digest, Sha256};
use std::io::Cursor;

fn samples(data: &[u8], width: usize, height: usize, channels: usize, depth: u8) -> Vec<u8> {
    let bits = width * channels * depth as usize;
    let stride = (bits + 7) / 8;
    let mut out = Vec::new();
    for y in 0..height {
        let row = &data[y * stride..(y + 1) * stride];
        for s in 0..width * channels {
            match depth {
                16 => out.extend_from_slice(&row[2 * s..2 * s + 2]),
                8 => out.push(row[s]),
                d => {
                    let bit = s * d as usize;
                    let byte = row[bit / 8];
                    out.push((byte >> (8 - d as usize - bit % 8)) & ((1u8 << d) - 1));
                }
            }
        }
    }
    out
}

fn describe(bytes: &[u8]) -> String {
    let mut decoder = png::Decoder::new(Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::IDENTITY);
    let mut reader = match decoder.read_info() {
        Ok(r) => r,
        Err(e) => return format!("error {:?}", e).split('(').next().unwrap().to_string(),
    };
    let info = reader.info();
    let mut line = format!("ok {}x{}", info.width, info.height);
    match &info.animation_control {
        Some(a) => line += &format!(" frames={} plays={}", a.num_frames, a.num_plays),
        None => line += " still",
    }
    let channels = info.color_type.samples();
    let depth = info.bit_depth as u8;
    let frames = info.animation_control.map(|a| a.num_frames as usize + 1).unwrap_or(1);
    let mut buf = vec![0; reader.output_buffer_size().unwrap_or(0)];
    for _ in 0..frames {
        match reader.next_frame(&mut buf) {
            Ok(out) => {
                let control = reader.info().frame_control().copied();
                let fields = match control {
                    Some(c) if out.width == c.width && out.height == c.height => format!(
                        "{},{} {}x{} {}/{} {} {}",
                        c.x_offset, c.y_offset, c.width, c.height, c.delay_num, c.delay_den,
                        c.dispose_op as u8, c.blend_op as u8
                    ),
                    _ => format!("- {}x{}", out.width, out.height),
                };
                let s = samples(&buf, out.width as usize, out.height as usize, channels, depth);
                let digest = Sha256::digest(&s);
                let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
                line += &format!("; {} {}", fields, hex);
            }
            Err(png::DecodingError::Parameter(_)) => break,
            Err(e) => {
                let kind = format!("{:?}", e);
                line += &format!("; error {}", kind.split('(').next().unwrap());
                break;
            }
        }
    }
    line
}

fn main() {
    for path in std::env::args().skip(1) {
        let bytes = std::fs::read(&path).expect("read");
        let name = std::path::Path::new(&path).file_name().unwrap().to_string_lossy();
        println!("{} {}", name, describe(&bytes));
    }
}
