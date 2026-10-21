///|
/// The modulus of both sums: the largest prime below 2^16.
const BASE : UInt32 = 65521

///|
/// The most bytes whose sums fit in 32 bits before reducing them (zlib's
/// NMAX): 255 n (n + 1) / 2 + (n + 1) (BASE - 1) <= 2^32 - 1.
const NMAX : Int32 = 5552

///|
/// The Adler-32 of no data.
pub const INITIAL : UInt32 = 1

///|
/// The Adler-32 of the data so far, `adler`, extended by `data`.
pub fn update(adler : UInt32, data : ArrayView[Byte]) -> UInt32 {
  let mut a = adler & 0xFFFF
  let mut b = adler >> 16
  let mut i = 0
  while i < data.length() {
    let end = (i + NMAX).min(data.length())
    for j in i..<end {
      a = a + data[j].to_uint()
      b = b + a
    }
    a = a % BASE
    b = b % BASE
    i = end
  }
  (b << 16) | a
}

///|
/// The Adler-32 of the data so far, `adler`, extended by `data`. The same as
/// `update`, for a `BytesView`, in the form `moon prove` checks: the sums
/// never pass 2^32 - 1 between reductions (see PROOFS.md).
pub fn update_bytes(
  adler : UInt32,
  data : BytesView,
) -> UInt32 where {
  proof_ensure: result => data.length() > 0 → adler_reduced(result),
} {
  let n = data.length()
  for i = 0, a = adler % 65536U, b = adler / 65536U; i < n; {
    // Not `end`: a Why3 keyword, which `moon prove` passes through.
    let stop = if n - i < NMAX { n } else { i + NMAX }
    let (a1, b1) = for j = i, a = a, b = b; j < stop; {
      let a2 = a + byte_u32(data[j])
      // The bound on b + a2 is quadratic in the bytes summed; spelled out
      // step by step for the solver.
      proof_assert um(a2).le(a_bound(j - i + 1))
      proof_assert tri(im(j - i)).le(im(5551).times(im(5552)))
      proof_assert um(b).plus(um(b)).le(b2_bound(5551))
      proof_assert um(a2).le(a_bound(5552))
      proof_assert um(b).plus(um(a2)).le(um(4294967295U))
      proof_assert tri(im(j - i)).eq(im(j - i).times(im(j - i)).plus(im(j - i)))
      proof_assert tri(im(j - i).plus(im(1))).eq(
        im(j - i).times(im(j - i)).plus(im(3).times(im(j - i))).plus(im(2)),
      )
      proof_assert tri_step(j - i)
      proof_assert chunk_inv(a2, b + a2, j + 1 - i)
      continue j + 1, a2, b + a2
    } nobreak {
      (a, b)
    } where {
      proof_invariant: i <= j && j <= stop && stop <= n && stop - i <= NMAX,
      proof_invariant: chunk_inv(a, b, j - i),
    }
    continue stop, a1 % BASE, b1 % BASE
  } nobreak {
    proof_assert (b * 65536U + a) % 65536U == a
    proof_assert (b * 65536U + a) / 65536U == b
    b * 65536U + a
  } where {
    proof_invariant: 0 <= i && i <= n,
    proof_invariant: a < 65536U && b < 65536U,
    proof_invariant: i > 0 → a < BASE && b < BASE,
  }
}

///|
/// The Adler-32 of `data`.
pub fn of_bytes(data : BytesView) -> UInt32 {
  update_bytes(INITIAL, data)
}
