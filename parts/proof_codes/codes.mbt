// Proof steps: functions that compute nothing and whose contracts are
// facts about the logic of codes.mbtp. `moon prove` proves each from its
// precondition here; a proof that calls one gets the fact where it needs it.
// (A lemma of codes.mbtp would join the context of every goal of every
// package that imports this one, and slow the solvers down on all of them;
// a program cannot call a lemma.)

///|
/// `space_left` is the recursion it stands for: each step doubles what is
/// left and takes the codes of the next length. Its table at `l + 1` is
/// checked against its table at `l`.
pub fn space_left_step(
  c : FixedArray[Int32],
  l : Int32,
) -> Unit where {
  proof_require: 0 <= l && l < 15,
  proof_ensure: space_left(c, l + 1) == 2 * space_left(c, l) - c[l + 1],
} {

}

///|
/// At 15 bits, what the counts leave is 2^15 minus their Kraft's sum.
pub fn kraft_space(
  c : FixedArray[Int32],
) -> Unit where {
  proof_ensure: kraft(c) == 32768 - space_left(c, 15),
} {

}

///|
/// With no code longer than one bit, Kraft's sum is that of the one-bit
/// codes.
pub fn kraft_one_bit(
  c : FixedArray[Int32],
) -> Unit where {
  proof_require: none_longer(c, 1),
  proof_ensure: kraft(c) == 16384 * c[1],
} {
  proof_assert c[2] == 0
  proof_assert c[3] == 0
  proof_assert c[4] == 0
  proof_assert c[5] == 0
  proof_assert c[6] == 0
  proof_assert c[7] == 0
  proof_assert c[8] == 0
  proof_assert c[9] == 0
  proof_assert c[10] == 0
  proof_assert c[11] == 0
  proof_assert c[12] == 0
  proof_assert c[13] == 0
  proof_assert c[14] == 0
  proof_assert c[15] == 0
}

///|
/// What `reverse_bits` proves its loop with: one more bit of `rev` puts bit
/// `i` of `code` below the reversed `i` bits, and dropping one more low bit
/// of `code` divides it by 2 again. For every `code` and `i` at once, so
/// that `reverse_bits` needs no call at all: it requires them, and a proof
/// that calls it gets them here once. (The halvings case by case, each in a
/// function of its own: with `2^i` a variable, or with the others in its
/// context, CVC5 does not prove them.)
pub fn reverse_facts(
  x : Int32,
) -> Unit where {
  proof_ensure: rev_steps(x) && halves(x),
} {
  rev_steps_hold(x)
  halves_hold(x)
}

///|
fn rev_steps_hold(x : Int32) -> Unit where { proof_ensure: rev_steps(x), } {

}

///|
fn halves_hold(x : Int32) -> Unit where { proof_ensure: halves(x), } {
  halves_at_0(x)
  halves_at_1(x)
  halves_at_2(x)
  halves_at_3(x)
  halves_at_4(x)
  halves_at_5(x)
  halves_at_6(x)
  halves_at_7(x)
  halves_at_8(x)
  halves_at_9(x)
  halves_at_10(x)
  halves_at_11(x)
  halves_at_12(x)
  halves_at_13(x)
  halves_at_14(x)
}

///|
fn halves_at_0(x : Int32) -> Unit where { proof_ensure: halves_at(x, 0), } {

}

///|
fn halves_at_1(x : Int32) -> Unit where { proof_ensure: halves_at(x, 1), } {

}

///|
fn halves_at_2(x : Int32) -> Unit where { proof_ensure: halves_at(x, 2), } {

}

///|
fn halves_at_3(x : Int32) -> Unit where { proof_ensure: halves_at(x, 3), } {

}

///|
fn halves_at_4(x : Int32) -> Unit where { proof_ensure: halves_at(x, 4), } {

}

///|
fn halves_at_5(x : Int32) -> Unit where { proof_ensure: halves_at(x, 5), } {

}

///|
fn halves_at_6(x : Int32) -> Unit where { proof_ensure: halves_at(x, 6), } {

}

///|
fn halves_at_7(x : Int32) -> Unit where { proof_ensure: halves_at(x, 7), } {

}

///|
fn halves_at_8(x : Int32) -> Unit where { proof_ensure: halves_at(x, 8), } {

}

///|
fn halves_at_9(x : Int32) -> Unit where { proof_ensure: halves_at(x, 9), } {

}

///|
fn halves_at_10(x : Int32) -> Unit where { proof_ensure: halves_at(x, 10), } {

}

///|
fn halves_at_11(x : Int32) -> Unit where { proof_ensure: halves_at(x, 11), } {

}

///|
fn halves_at_12(x : Int32) -> Unit where { proof_ensure: halves_at(x, 12), } {

}

///|
fn halves_at_13(x : Int32) -> Unit where { proof_ensure: halves_at(x, 13), } {

}

///|
fn halves_at_14(x : Int32) -> Unit where { proof_ensure: halves_at(x, 14), } {

}

///|
/// The first code of one bit is 0.
pub fn first_code_one(
  c : FixedArray[Int32],
) -> Unit where {
  proof_ensure: first_code(c, 1) == 0,
} {

}

///|
/// Each length's first code is twice the end of the codes of the length
/// before (RFC 1951 section 3.2.2, step 2).
pub fn first_code_step(
  c : FixedArray[Int32],
  l : Int32,
) -> Unit where {
  proof_require: 1 <= l && l < 15,
  proof_ensure: first_code(c, l + 1) == 2 * (first_code(c, l) + c[l]),
} {

}

///|
/// Counting one more entry of `a`: the count of its value goes up by one.
pub fn count_step(
  a : FixedArray[Int32],
  i : Int32,
) -> Unit where {
  proof_require: 0 <= i && i < a.length(),
  proof_ensure: numof(a, a[i], 0, i + 1) == numof(a, a[i], 0, i) + 1,
} {

}

///|
/// Counting one more entry of `a`: the counts of the other values stay.
pub fn count_others(
  a : FixedArray[Int32],
  i : Int32,
) -> Unit where {
  proof_require: 0 <= i && i < a.length(),
  proof_ensure: others_stay(a, i),
} {

}

///|
/// The count of `v` in `a[0..u)` is at least its count in `a[0..t)` for
/// `t <= u`, and more when `a[t]` is `v` and `t < u`.
pub fn count_grows(
  a : FixedArray[Int32],
  v : Int32,
  t : Int32,
  u : Int32,
) -> Unit where {
  proof_require: 0 <= t && t <= u,
  proof_ensure: numof(a, v, 0, t) <= numof(a, v, 0, u) && 0 <= numof(a, v, 0, t),
} {
  proof_assert numof(a, v, 0, u) == numof(a, v, 0, t) + numof(a, v, t, u)
}
