///|
/// What the code lengths of a complex prefix code make (RFC 7932 section
/// 3.5): a complete code, a single symbol with a length (which the code
/// length code allows, as a code of zero bits), or neither.
pub(all) enum CodeShape {
  Complete
  Single
  Other
}

///|
/// The shape of the code lengths `lengths[0:n]`, each 0 to 15 and `n` at
/// most 704 (the decoder's largest alphabet), with `counts` (16 entries)
/// as scratch space: `Complete` exactly when Kraft's
/// sum of the lengths is 1, `Single` when it is not and one length is not 0.
/// The decoder decides with it once it has read the lengths; the code space
/// it counts as it reads them only says when to stop reading.
pub fn code_shape(
  lengths : FixedArray[Int32],
  n : Int32,
  counts : FixedArray[Int32],
) -> CodeShape where {
  proof_require: code_shape_pre(lengths, n, counts),
  proof_ensure: result => code_shape_post(lengths, n, counts, result),
} {
  for l = 0; l < 16; {
    counts[l] = 0
    continue l + 1
  } where {
    proof_invariant: 0 <= l && l <= 16,
    proof_invariant: counts.length() == 16,
    proof_invariant: zero_below(counts, l),
  }
  for s = 0; s < n; {
    counts[lengths[s]] = counts[lengths[s]] + 1
    continue s + 1
  } where {
    proof_invariant: 0 <= s && s <= n,
    proof_invariant: counts.length() == 16,
    proof_invariant: @proof_codes.counted(counts, lengths, s),
  }
  // The code space left after each length: 0 at the end is a complete code.
  let mut left = 1
  for l = 1; l < 16; {
    @proof_codes.space_left_step(counts, l - 1)
    left = 2 * left - counts[l]
    continue l + 1
  } where {
    proof_invariant: 1 <= l && l <= 16,
    proof_invariant: left == @proof_codes.space_left(counts, l - 1),
  }
  @proof_codes.kraft_space(counts)
  let used = counts[1] +
    counts[2] +
    counts[3] +
    counts[4] +
    counts[5] +
    counts[6] +
    counts[7] +
    counts[8] +
    counts[9] +
    counts[10] +
    counts[11] +
    counts[12] +
    counts[13] +
    counts[14] +
    counts[15]
  if left == 0 {
    Complete
  } else if used == 1 {
    Single
  } else {
    Other
  }
}
