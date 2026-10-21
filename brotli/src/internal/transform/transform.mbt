// The transform of a static dictionary word (RFC 7932 section 8): the root
// package looks up the transform's prefix, suffix and elementary transform
// (Appendix B) and the word, already cut to what the transform keeps.

///|
/// Writes `prefix`, then `word` uppercased as `kind` says (10 FermentFirst,
/// 11 FermentAll, anything else as it is), then `suffix` into `out` from 0,
/// and returns how many bytes it wrote. `out` must have room for the three,
/// and FermentFirst a word to uppercase.
pub fn transform_into(
  out : FixedArray[Byte],
  prefix : BytesView,
  word : BytesView,
  kind : Int32,
  suffix : BytesView,
) -> Int32 where {
  proof_require: transform_pre(out, prefix, word, kind, suffix),
  proof_ensure: result => {
    result == prefix.length() + word.length() + suffix.length()
  },
} {
  let np = prefix.length()
  let nw = word.length()
  let ns = suffix.length()
  for i = 0; i < np; {
    out[i] = prefix[i]
    continue i + 1
  } where {
    proof_invariant: 0 <= i && i <= np,
    proof_invariant: transform_pre(out, prefix, word, kind, suffix),
  }
  for i = 0; i < nw; {
    out[np + i] = word[i]
    continue i + 1
  } where {
    proof_invariant: 0 <= i && i <= nw,
    proof_invariant: transform_pre(out, prefix, word, kind, suffix),
  }
  if kind == 10 {
    let _ = ferment(out, np, nw, 0)
  } else if kind == 11 {
    for i = 0; i < nw; {
      continue i + ferment(out, np, nw, i)
    } where {
      proof_invariant: 0 <= i,
      proof_invariant: transform_pre(out, prefix, word, kind, suffix),
    }
  }
  let n = np + nw
  for i = 0; i < ns; {
    out[n + i] = suffix[i]
    continue i + 1
  } where {
    proof_invariant: 0 <= i && i <= ns,
    proof_invariant: transform_pre(out, prefix, word, kind, suffix),
  }
  n + ns
}

///|
/// RFC 7932's `Ferment`: uppercases the character at `pos` of the word at
/// `out[start:start + length]` and returns its length in bytes.
fn ferment(
  out : FixedArray[Byte],
  start : Int32,
  length : Int32,
  pos : Int32,
) -> Int32 where {
  proof_require: ferment_pre(out, start, length, pos),
  proof_ensure: result => 1 <= result && result <= 3,
} {
  let c = out[start + pos]
  if c < 192 {
    if c >= 97 && c <= 122 {
      out[start + pos] = flip(c, 32)
    }
    1
  } else if c < 224 {
    if pos + 1 < length {
      out[start + pos + 1] = flip(out[start + pos + 1], 32)
    }
    2
  } else {
    if pos + 2 < length {
      out[start + pos + 2] = flip(out[start + pos + 2], 5)
    }
    3
  }
}

///|
/// `b ^ mask`: the prover has no `^` on bytes. Its contract claims no more
/// than that the result is a byte: the proofs here are about where bytes go,
/// not what they are.
fn flip(
  b : Byte,
  mask : Byte,
) -> Byte where {
  proof_axiomatized: true,
  proof_ensure: result => 0 <= result.to_int() && result.to_int() <= 255,
} {
  b ^ mask
}
