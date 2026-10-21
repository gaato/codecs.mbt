// The inverse move-to-front transform of context maps (RFC 7932 section
// 7.3).

///|
/// Replaces `values[0..n)` by their inverse move-to-front transform: each
/// value is an index into a list that starts as 0 to 255, and becomes the
/// entry at that index, which then moves to the front of the list. Writes
/// nothing else.
pub fn inverse_move_to_front(
  values : FixedArray[Byte],
  n : Int32,
) -> Unit where {
  proof_require: 0 <= n && n <= values.length(),
} {
  let mtf = FixedArray::make(256, b'\x00')
  for i = 0; i < 256; {
    mtf[i] = byte_of(i)
    continue i + 1
  } where {
    proof_invariant: 0 <= i && i <= 256,
    proof_invariant: identity_prefix(mtf, i),
  }
  for i = 0; i < n; {
    values[i] = move_to_front(mtf, values[i].to_int())
    continue i + 1
  } where {
    proof_invariant: 0 <= i && i <= n,
    proof_invariant: mtf_perm(mtf),
  }
}

///|
/// Moves `mtf[index]` to the front of `mtf`, a permutation of 0 to 255, and
/// returns it.
fn move_to_front(
  mtf : FixedArray[Byte],
  index : Int32,
) -> Byte where {
  proof_require: mtf_perm(mtf) && 0 <= index && index < 256,
  proof_ensure: result => mtf_perm(mtf) && mtf[0] == result,
} {
  let value = mtf[index]
  // Counting up, so that `moon prove` sees the loop end.
  for k = 0; k < index; {
    mtf[index - k] = mtf[index - k - 1]
    continue k + 1
  } where {
    proof_invariant: 0 <= k && k <= index,
    proof_invariant: mtf.length() == 256,
    proof_invariant: perm_except(mtf, index - k, value),
  }
  mtf[0] = value
  value
}
