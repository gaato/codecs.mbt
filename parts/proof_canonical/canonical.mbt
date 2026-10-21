///|
/// The table of `kraft_upto` takes the codes of one more length at a time.
fn kraft_upto_step(
  c : FixedArray[Int32],
  m : Int32,
) -> Unit where {
  proof_require: 0 <= m && m < 15,
  proof_ensure: kraft_upto(c, m + 1) ==
  kraft_upto(c, m) + @proof_bits.pow2(14 - m) * c[m + 1],
} {
  if m == 0 {
    proof_assert kraft_upto(c, 1) == kraft_upto(c, 0) + 16384 * c[1]
  } else if m == 1 {
    proof_assert kraft_upto(c, 2) == kraft_upto(c, 1) + 8192 * c[2]
  } else if m == 2 {
    proof_assert kraft_upto(c, 3) == kraft_upto(c, 2) + 4096 * c[3]
  } else if m == 3 {
    proof_assert kraft_upto(c, 4) == kraft_upto(c, 3) + 2048 * c[4]
  } else if m == 4 {
    proof_assert kraft_upto(c, 5) == kraft_upto(c, 4) + 1024 * c[5]
  } else if m == 5 {
    proof_assert kraft_upto(c, 6) == kraft_upto(c, 5) + 512 * c[6]
  } else if m == 6 {
    proof_assert kraft_upto(c, 7) == kraft_upto(c, 6) + 256 * c[7]
  } else if m == 7 {
    proof_assert kraft_upto(c, 8) == kraft_upto(c, 7) + 128 * c[8]
  } else if m == 8 {
    proof_assert kraft_upto(c, 9) == kraft_upto(c, 8) + 64 * c[9]
  } else if m == 9 {
    proof_assert kraft_upto(c, 10) == kraft_upto(c, 9) + 32 * c[10]
  } else if m == 10 {
    proof_assert kraft_upto(c, 11) == kraft_upto(c, 10) + 16 * c[11]
  } else if m == 11 {
    proof_assert kraft_upto(c, 12) == kraft_upto(c, 11) + 8 * c[12]
  } else if m == 12 {
    proof_assert kraft_upto(c, 13) == kraft_upto(c, 12) + 4 * c[13]
  } else if m == 13 {
    proof_assert kraft_upto(c, 14) == kraft_upto(c, 13) + 2 * c[14]
  } else if m == 14 {
    proof_assert kraft_upto(c, 15) == kraft_upto(c, 14) + 1 * c[15]
  }
}

///|
/// The first code of `l` bits, scaled to 15 bits, is where the codes up to
/// `l - 1` bits end.
fn first_scaled(
  c : FixedArray[Int32],
  l : Int32,
) -> Unit where {
  proof_require: 1 <= l && l <= 15,
  proof_ensure: @proof_codes.first_code(c, l) * @proof_bits.pow2(15 - l) ==
  kraft_upto(c, l - 1),
} {
  if l == 1 {
    proof_assert @proof_codes.first_code(c, 1) * 16384 == kraft_upto(c, 0)
  } else if l == 2 {
    proof_assert @proof_codes.first_code(c, 2) * 8192 == kraft_upto(c, 1)
  } else if l == 3 {
    proof_assert @proof_codes.first_code(c, 3) * 4096 == kraft_upto(c, 2)
  } else if l == 4 {
    proof_assert @proof_codes.first_code(c, 4) * 2048 == kraft_upto(c, 3)
  } else if l == 5 {
    proof_assert @proof_codes.first_code(c, 5) * 1024 == kraft_upto(c, 4)
  } else if l == 6 {
    proof_assert @proof_codes.first_code(c, 6) * 512 == kraft_upto(c, 5)
  } else if l == 7 {
    proof_assert @proof_codes.first_code(c, 7) * 256 == kraft_upto(c, 6)
  } else if l == 8 {
    proof_assert @proof_codes.first_code(c, 8) * 128 == kraft_upto(c, 7)
  } else if l == 9 {
    proof_assert @proof_codes.first_code(c, 9) * 64 == kraft_upto(c, 8)
  } else if l == 10 {
    proof_assert @proof_codes.first_code(c, 10) * 32 == kraft_upto(c, 9)
  } else if l == 11 {
    proof_assert @proof_codes.first_code(c, 11) * 16 == kraft_upto(c, 10)
  } else if l == 12 {
    proof_assert @proof_codes.first_code(c, 12) * 8 == kraft_upto(c, 11)
  } else if l == 13 {
    proof_assert @proof_codes.first_code(c, 13) * 4 == kraft_upto(c, 12)
  } else if l == 14 {
    proof_assert @proof_codes.first_code(c, 14) * 2 == kraft_upto(c, 13)
  } else if l == 15 {
    proof_assert @proof_codes.first_code(c, 15) * 1 == kraft_upto(c, 14)
  }
}

///|
/// Kraft's sum is the sum up to 15 bits.
fn kraft_all(
  c : FixedArray[Int32],
) -> Unit where {
  proof_ensure: kraft_upto(c, 15) == @proof_codes.kraft(c),
} {

}

///|
/// With counts that are not negative, `kraft_upto` grows with its length.
fn kraft_upto_grows(
  c : FixedArray[Int32],
  i : Int32,
  j : Int32,
) -> Unit where {
  proof_require: 0 <= i && i <= j && j <= 15 && @proof_codes.counts_nonneg(c),
  proof_ensure: kraft_upto(c, i) <= kraft_upto(c, j),
} {
  for m = i; m < j; {
    kraft_upto_step(c, m)
    proof_assert c[m + 1] >= 0
    continue m + 1
  } where {
    proof_invariant: i <= m && m <= j,
    proof_invariant: kraft_upto(c, i) <= kraft_upto(c, m),
  }
}

///|
/// The codes that start with `s`'s code end where the codes of its length
/// do or before. (Case by case, each step with constant powers of two: the
/// solvers do not multiply by a variable `2^(15 - l)` here.)
fn code_end_bound(
  c : FixedArray[Int32],
  lengths : FixedArray[Int32],
  n : Int32,
  s : Int32,
) -> Unit where {
  proof_require: coded_at(c, lengths, n, s),
  proof_ensure: code_end(c, lengths, s) <= kraft_upto(c, lengths[s]),
} {
  let l = lengths[s]
  proof_assert @proof_codes.numof(lengths, l, 0, n) ==
    @proof_codes.numof(lengths, l, 0, s) + @proof_codes.numof(lengths, l, s, n)
  proof_assert @proof_codes.numof(lengths, l, s, n) >= 1
  proof_assert @proof_codes.numof(lengths, l, 0, s) + 1 <= c[l]
  kraft_upto_step(c, l - 1)
  if l == 1 {
    first_scaled(c, 1)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 1) + @proof_codes.numof(lengths, 1, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 1) * 16384 +
      (@proof_codes.numof(lengths, 1, 0, s) + 1) * 16384
    proof_assert @proof_codes.first_code(c, 1) * 16384 == kraft_upto(c, 0)
    proof_assert (@proof_codes.numof(lengths, 1, 0, s) + 1) * 16384 <=
      c[1] * 16384
  } else if l == 2 {
    first_scaled(c, 2)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 2) + @proof_codes.numof(lengths, 2, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 2) * 8192 +
      (@proof_codes.numof(lengths, 2, 0, s) + 1) * 8192
    proof_assert @proof_codes.first_code(c, 2) * 8192 == kraft_upto(c, 1)
    proof_assert (@proof_codes.numof(lengths, 2, 0, s) + 1) * 8192 <=
      c[2] * 8192
  } else if l == 3 {
    first_scaled(c, 3)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 3) + @proof_codes.numof(lengths, 3, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 3) * 4096 +
      (@proof_codes.numof(lengths, 3, 0, s) + 1) * 4096
    proof_assert @proof_codes.first_code(c, 3) * 4096 == kraft_upto(c, 2)
    proof_assert (@proof_codes.numof(lengths, 3, 0, s) + 1) * 4096 <=
      c[3] * 4096
  } else if l == 4 {
    first_scaled(c, 4)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 4) + @proof_codes.numof(lengths, 4, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 4) * 2048 +
      (@proof_codes.numof(lengths, 4, 0, s) + 1) * 2048
    proof_assert @proof_codes.first_code(c, 4) * 2048 == kraft_upto(c, 3)
    proof_assert (@proof_codes.numof(lengths, 4, 0, s) + 1) * 2048 <=
      c[4] * 2048
  } else if l == 5 {
    first_scaled(c, 5)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 5) + @proof_codes.numof(lengths, 5, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 5) * 1024 +
      (@proof_codes.numof(lengths, 5, 0, s) + 1) * 1024
    proof_assert @proof_codes.first_code(c, 5) * 1024 == kraft_upto(c, 4)
    proof_assert (@proof_codes.numof(lengths, 5, 0, s) + 1) * 1024 <=
      c[5] * 1024
  } else if l == 6 {
    first_scaled(c, 6)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 6) + @proof_codes.numof(lengths, 6, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 6) * 512 +
      (@proof_codes.numof(lengths, 6, 0, s) + 1) * 512
    proof_assert @proof_codes.first_code(c, 6) * 512 == kraft_upto(c, 5)
    proof_assert (@proof_codes.numof(lengths, 6, 0, s) + 1) * 512 <= c[6] * 512
  } else if l == 7 {
    first_scaled(c, 7)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 7) + @proof_codes.numof(lengths, 7, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 7) * 256 +
      (@proof_codes.numof(lengths, 7, 0, s) + 1) * 256
    proof_assert @proof_codes.first_code(c, 7) * 256 == kraft_upto(c, 6)
    proof_assert (@proof_codes.numof(lengths, 7, 0, s) + 1) * 256 <= c[7] * 256
  } else if l == 8 {
    first_scaled(c, 8)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 8) + @proof_codes.numof(lengths, 8, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 8) * 128 +
      (@proof_codes.numof(lengths, 8, 0, s) + 1) * 128
    proof_assert @proof_codes.first_code(c, 8) * 128 == kraft_upto(c, 7)
    proof_assert (@proof_codes.numof(lengths, 8, 0, s) + 1) * 128 <= c[8] * 128
  } else if l == 9 {
    first_scaled(c, 9)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 9) + @proof_codes.numof(lengths, 9, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 9) * 64 +
      (@proof_codes.numof(lengths, 9, 0, s) + 1) * 64
    proof_assert @proof_codes.first_code(c, 9) * 64 == kraft_upto(c, 8)
    proof_assert (@proof_codes.numof(lengths, 9, 0, s) + 1) * 64 <= c[9] * 64
  } else if l == 10 {
    first_scaled(c, 10)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 10) + @proof_codes.numof(lengths, 10, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 10) * 32 +
      (@proof_codes.numof(lengths, 10, 0, s) + 1) * 32
    proof_assert @proof_codes.first_code(c, 10) * 32 == kraft_upto(c, 9)
    proof_assert (@proof_codes.numof(lengths, 10, 0, s) + 1) * 32 <= c[10] * 32
  } else if l == 11 {
    first_scaled(c, 11)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 11) + @proof_codes.numof(lengths, 11, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 11) * 16 +
      (@proof_codes.numof(lengths, 11, 0, s) + 1) * 16
    proof_assert @proof_codes.first_code(c, 11) * 16 == kraft_upto(c, 10)
    proof_assert (@proof_codes.numof(lengths, 11, 0, s) + 1) * 16 <= c[11] * 16
  } else if l == 12 {
    first_scaled(c, 12)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 12) + @proof_codes.numof(lengths, 12, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 12) * 8 +
      (@proof_codes.numof(lengths, 12, 0, s) + 1) * 8
    proof_assert @proof_codes.first_code(c, 12) * 8 == kraft_upto(c, 11)
    proof_assert (@proof_codes.numof(lengths, 12, 0, s) + 1) * 8 <= c[12] * 8
  } else if l == 13 {
    first_scaled(c, 13)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 13) + @proof_codes.numof(lengths, 13, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 13) * 4 +
      (@proof_codes.numof(lengths, 13, 0, s) + 1) * 4
    proof_assert @proof_codes.first_code(c, 13) * 4 == kraft_upto(c, 12)
    proof_assert (@proof_codes.numof(lengths, 13, 0, s) + 1) * 4 <= c[13] * 4
  } else if l == 14 {
    first_scaled(c, 14)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 14) + @proof_codes.numof(lengths, 14, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 14) * 2 +
      (@proof_codes.numof(lengths, 14, 0, s) + 1) * 2
    proof_assert @proof_codes.first_code(c, 14) * 2 == kraft_upto(c, 13)
    proof_assert (@proof_codes.numof(lengths, 14, 0, s) + 1) * 2 <= c[14] * 2
  } else if l == 15 {
    first_scaled(c, 15)
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 15) + @proof_codes.numof(lengths, 15, 0, s)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 15) * 1 +
      (@proof_codes.numof(lengths, 15, 0, s) + 1) * 1
    proof_assert @proof_codes.first_code(c, 15) * 1 == kraft_upto(c, 14)
    proof_assert (@proof_codes.numof(lengths, 15, 0, s) + 1) * 1 <= c[15] * 1
  }
}

///|
/// The codes that start with `t`'s code start where the codes shorter than
/// it end or after.
fn code_start_bound(
  c : FixedArray[Int32],
  lengths : FixedArray[Int32],
  n : Int32,
  t : Int32,
) -> Unit where {
  proof_require: coded_at(c, lengths, n, t),
  proof_ensure: code_start(c, lengths, t) >= kraft_upto(c, lengths[t] - 1),
} {
  let l = lengths[t]
  proof_assert @proof_codes.numof(lengths, l, 0, t) >= 0
  if l == 1 {
    first_scaled(c, 1)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 1) + @proof_codes.numof(lengths, 1, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 1) * 16384 +
      @proof_codes.numof(lengths, 1, 0, t) * 16384
    proof_assert @proof_codes.first_code(c, 1) * 16384 == kraft_upto(c, 0)
    proof_assert @proof_codes.numof(lengths, 1, 0, t) * 16384 >= 0
  } else if l == 2 {
    first_scaled(c, 2)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 2) + @proof_codes.numof(lengths, 2, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 2) * 8192 +
      @proof_codes.numof(lengths, 2, 0, t) * 8192
    proof_assert @proof_codes.first_code(c, 2) * 8192 == kraft_upto(c, 1)
    proof_assert @proof_codes.numof(lengths, 2, 0, t) * 8192 >= 0
  } else if l == 3 {
    first_scaled(c, 3)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 3) + @proof_codes.numof(lengths, 3, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 3) * 4096 +
      @proof_codes.numof(lengths, 3, 0, t) * 4096
    proof_assert @proof_codes.first_code(c, 3) * 4096 == kraft_upto(c, 2)
    proof_assert @proof_codes.numof(lengths, 3, 0, t) * 4096 >= 0
  } else if l == 4 {
    first_scaled(c, 4)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 4) + @proof_codes.numof(lengths, 4, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 4) * 2048 +
      @proof_codes.numof(lengths, 4, 0, t) * 2048
    proof_assert @proof_codes.first_code(c, 4) * 2048 == kraft_upto(c, 3)
    proof_assert @proof_codes.numof(lengths, 4, 0, t) * 2048 >= 0
  } else if l == 5 {
    first_scaled(c, 5)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 5) + @proof_codes.numof(lengths, 5, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 5) * 1024 +
      @proof_codes.numof(lengths, 5, 0, t) * 1024
    proof_assert @proof_codes.first_code(c, 5) * 1024 == kraft_upto(c, 4)
    proof_assert @proof_codes.numof(lengths, 5, 0, t) * 1024 >= 0
  } else if l == 6 {
    first_scaled(c, 6)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 6) + @proof_codes.numof(lengths, 6, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 6) * 512 +
      @proof_codes.numof(lengths, 6, 0, t) * 512
    proof_assert @proof_codes.first_code(c, 6) * 512 == kraft_upto(c, 5)
    proof_assert @proof_codes.numof(lengths, 6, 0, t) * 512 >= 0
  } else if l == 7 {
    first_scaled(c, 7)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 7) + @proof_codes.numof(lengths, 7, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 7) * 256 +
      @proof_codes.numof(lengths, 7, 0, t) * 256
    proof_assert @proof_codes.first_code(c, 7) * 256 == kraft_upto(c, 6)
    proof_assert @proof_codes.numof(lengths, 7, 0, t) * 256 >= 0
  } else if l == 8 {
    first_scaled(c, 8)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 8) + @proof_codes.numof(lengths, 8, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 8) * 128 +
      @proof_codes.numof(lengths, 8, 0, t) * 128
    proof_assert @proof_codes.first_code(c, 8) * 128 == kraft_upto(c, 7)
    proof_assert @proof_codes.numof(lengths, 8, 0, t) * 128 >= 0
  } else if l == 9 {
    first_scaled(c, 9)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 9) + @proof_codes.numof(lengths, 9, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 9) * 64 +
      @proof_codes.numof(lengths, 9, 0, t) * 64
    proof_assert @proof_codes.first_code(c, 9) * 64 == kraft_upto(c, 8)
    proof_assert @proof_codes.numof(lengths, 9, 0, t) * 64 >= 0
  } else if l == 10 {
    first_scaled(c, 10)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 10) + @proof_codes.numof(lengths, 10, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 10) * 32 +
      @proof_codes.numof(lengths, 10, 0, t) * 32
    proof_assert @proof_codes.first_code(c, 10) * 32 == kraft_upto(c, 9)
    proof_assert @proof_codes.numof(lengths, 10, 0, t) * 32 >= 0
  } else if l == 11 {
    first_scaled(c, 11)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 11) + @proof_codes.numof(lengths, 11, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 11) * 16 +
      @proof_codes.numof(lengths, 11, 0, t) * 16
    proof_assert @proof_codes.first_code(c, 11) * 16 == kraft_upto(c, 10)
    proof_assert @proof_codes.numof(lengths, 11, 0, t) * 16 >= 0
  } else if l == 12 {
    first_scaled(c, 12)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 12) + @proof_codes.numof(lengths, 12, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 12) * 8 +
      @proof_codes.numof(lengths, 12, 0, t) * 8
    proof_assert @proof_codes.first_code(c, 12) * 8 == kraft_upto(c, 11)
    proof_assert @proof_codes.numof(lengths, 12, 0, t) * 8 >= 0
  } else if l == 13 {
    first_scaled(c, 13)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 13) + @proof_codes.numof(lengths, 13, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 13) * 4 +
      @proof_codes.numof(lengths, 13, 0, t) * 4
    proof_assert @proof_codes.first_code(c, 13) * 4 == kraft_upto(c, 12)
    proof_assert @proof_codes.numof(lengths, 13, 0, t) * 4 >= 0
  } else if l == 14 {
    first_scaled(c, 14)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 14) + @proof_codes.numof(lengths, 14, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 14) * 2 +
      @proof_codes.numof(lengths, 14, 0, t) * 2
    proof_assert @proof_codes.first_code(c, 14) * 2 == kraft_upto(c, 13)
    proof_assert @proof_codes.numof(lengths, 14, 0, t) * 2 >= 0
  } else if l == 15 {
    first_scaled(c, 15)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 15) + @proof_codes.numof(lengths, 15, 0, t)
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 15) * 1 +
      @proof_codes.numof(lengths, 15, 0, t) * 1
    proof_assert @proof_codes.first_code(c, 15) * 1 == kraft_upto(c, 14)
    proof_assert @proof_codes.numof(lengths, 15, 0, t) * 1 >= 0
  }
}

///|
/// Of two codes of the same length, the smaller symbol's comes first and is
/// not a prefix of the other's.
fn same_length_order(
  c : FixedArray[Int32],
  lengths : FixedArray[Int32],
  n : Int32,
  s : Int32,
  t : Int32,
) -> Unit where {
  proof_require: order_pre(c, lengths, n, s, t) && lengths[s] == lengths[t],
  proof_ensure: code_end(c, lengths, s) <= code_start(c, lengths, t),
} {
  let l = lengths[s]
  proof_assert @proof_codes.numof(lengths, l, 0, t) ==
    @proof_codes.numof(lengths, l, 0, s) + @proof_codes.numof(lengths, l, s, t)
  proof_assert @proof_codes.numof(lengths, l, s, t) >= 1
  if l == 1 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 1) + @proof_codes.numof(lengths, 1, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 1) + @proof_codes.numof(lengths, 1, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 1) * 16384 +
      (@proof_codes.numof(lengths, 1, 0, s) + 1) * 16384
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 1) * 16384 +
      @proof_codes.numof(lengths, 1, 0, t) * 16384
    proof_assert (@proof_codes.numof(lengths, 1, 0, s) + 1) * 16384 <=
      @proof_codes.numof(lengths, 1, 0, t) * 16384
  } else if l == 2 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 2) + @proof_codes.numof(lengths, 2, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 2) + @proof_codes.numof(lengths, 2, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 2) * 8192 +
      (@proof_codes.numof(lengths, 2, 0, s) + 1) * 8192
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 2) * 8192 +
      @proof_codes.numof(lengths, 2, 0, t) * 8192
    proof_assert (@proof_codes.numof(lengths, 2, 0, s) + 1) * 8192 <=
      @proof_codes.numof(lengths, 2, 0, t) * 8192
  } else if l == 3 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 3) + @proof_codes.numof(lengths, 3, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 3) + @proof_codes.numof(lengths, 3, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 3) * 4096 +
      (@proof_codes.numof(lengths, 3, 0, s) + 1) * 4096
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 3) * 4096 +
      @proof_codes.numof(lengths, 3, 0, t) * 4096
    proof_assert (@proof_codes.numof(lengths, 3, 0, s) + 1) * 4096 <=
      @proof_codes.numof(lengths, 3, 0, t) * 4096
  } else if l == 4 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 4) + @proof_codes.numof(lengths, 4, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 4) + @proof_codes.numof(lengths, 4, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 4) * 2048 +
      (@proof_codes.numof(lengths, 4, 0, s) + 1) * 2048
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 4) * 2048 +
      @proof_codes.numof(lengths, 4, 0, t) * 2048
    proof_assert (@proof_codes.numof(lengths, 4, 0, s) + 1) * 2048 <=
      @proof_codes.numof(lengths, 4, 0, t) * 2048
  } else if l == 5 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 5) + @proof_codes.numof(lengths, 5, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 5) + @proof_codes.numof(lengths, 5, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 5) * 1024 +
      (@proof_codes.numof(lengths, 5, 0, s) + 1) * 1024
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 5) * 1024 +
      @proof_codes.numof(lengths, 5, 0, t) * 1024
    proof_assert (@proof_codes.numof(lengths, 5, 0, s) + 1) * 1024 <=
      @proof_codes.numof(lengths, 5, 0, t) * 1024
  } else if l == 6 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 6) + @proof_codes.numof(lengths, 6, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 6) + @proof_codes.numof(lengths, 6, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 6) * 512 +
      (@proof_codes.numof(lengths, 6, 0, s) + 1) * 512
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 6) * 512 +
      @proof_codes.numof(lengths, 6, 0, t) * 512
    proof_assert (@proof_codes.numof(lengths, 6, 0, s) + 1) * 512 <=
      @proof_codes.numof(lengths, 6, 0, t) * 512
  } else if l == 7 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 7) + @proof_codes.numof(lengths, 7, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 7) + @proof_codes.numof(lengths, 7, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 7) * 256 +
      (@proof_codes.numof(lengths, 7, 0, s) + 1) * 256
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 7) * 256 +
      @proof_codes.numof(lengths, 7, 0, t) * 256
    proof_assert (@proof_codes.numof(lengths, 7, 0, s) + 1) * 256 <=
      @proof_codes.numof(lengths, 7, 0, t) * 256
  } else if l == 8 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 8) + @proof_codes.numof(lengths, 8, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 8) + @proof_codes.numof(lengths, 8, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 8) * 128 +
      (@proof_codes.numof(lengths, 8, 0, s) + 1) * 128
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 8) * 128 +
      @proof_codes.numof(lengths, 8, 0, t) * 128
    proof_assert (@proof_codes.numof(lengths, 8, 0, s) + 1) * 128 <=
      @proof_codes.numof(lengths, 8, 0, t) * 128
  } else if l == 9 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 9) + @proof_codes.numof(lengths, 9, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 9) + @proof_codes.numof(lengths, 9, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 9) * 64 +
      (@proof_codes.numof(lengths, 9, 0, s) + 1) * 64
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 9) * 64 +
      @proof_codes.numof(lengths, 9, 0, t) * 64
    proof_assert (@proof_codes.numof(lengths, 9, 0, s) + 1) * 64 <=
      @proof_codes.numof(lengths, 9, 0, t) * 64
  } else if l == 10 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 10) + @proof_codes.numof(lengths, 10, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 10) + @proof_codes.numof(lengths, 10, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 10) * 32 +
      (@proof_codes.numof(lengths, 10, 0, s) + 1) * 32
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 10) * 32 +
      @proof_codes.numof(lengths, 10, 0, t) * 32
    proof_assert (@proof_codes.numof(lengths, 10, 0, s) + 1) * 32 <=
      @proof_codes.numof(lengths, 10, 0, t) * 32
  } else if l == 11 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 11) + @proof_codes.numof(lengths, 11, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 11) + @proof_codes.numof(lengths, 11, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 11) * 16 +
      (@proof_codes.numof(lengths, 11, 0, s) + 1) * 16
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 11) * 16 +
      @proof_codes.numof(lengths, 11, 0, t) * 16
    proof_assert (@proof_codes.numof(lengths, 11, 0, s) + 1) * 16 <=
      @proof_codes.numof(lengths, 11, 0, t) * 16
  } else if l == 12 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 12) + @proof_codes.numof(lengths, 12, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 12) + @proof_codes.numof(lengths, 12, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 12) * 8 +
      (@proof_codes.numof(lengths, 12, 0, s) + 1) * 8
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 12) * 8 +
      @proof_codes.numof(lengths, 12, 0, t) * 8
    proof_assert (@proof_codes.numof(lengths, 12, 0, s) + 1) * 8 <=
      @proof_codes.numof(lengths, 12, 0, t) * 8
  } else if l == 13 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 13) + @proof_codes.numof(lengths, 13, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 13) + @proof_codes.numof(lengths, 13, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 13) * 4 +
      (@proof_codes.numof(lengths, 13, 0, s) + 1) * 4
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 13) * 4 +
      @proof_codes.numof(lengths, 13, 0, t) * 4
    proof_assert (@proof_codes.numof(lengths, 13, 0, s) + 1) * 4 <=
      @proof_codes.numof(lengths, 13, 0, t) * 4
  } else if l == 14 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 14) + @proof_codes.numof(lengths, 14, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 14) + @proof_codes.numof(lengths, 14, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 14) * 2 +
      (@proof_codes.numof(lengths, 14, 0, s) + 1) * 2
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 14) * 2 +
      @proof_codes.numof(lengths, 14, 0, t) * 2
    proof_assert (@proof_codes.numof(lengths, 14, 0, s) + 1) * 2 <=
      @proof_codes.numof(lengths, 14, 0, t) * 2
  } else if l == 15 {
    proof_assert @proof_codes.canonical(c, lengths, s) ==
      @proof_codes.first_code(c, 15) + @proof_codes.numof(lengths, 15, 0, s)
    proof_assert @proof_codes.canonical(c, lengths, t) ==
      @proof_codes.first_code(c, 15) + @proof_codes.numof(lengths, 15, 0, t)
    proof_assert code_end(c, lengths, s) ==
      @proof_codes.first_code(c, 15) * 1 +
      (@proof_codes.numof(lengths, 15, 0, s) + 1) * 1
    proof_assert code_start(c, lengths, t) ==
      @proof_codes.first_code(c, 15) * 1 +
      @proof_codes.numof(lengths, 15, 0, t) * 1
    proof_assert (@proof_codes.numof(lengths, 15, 0, s) + 1) * 1 <=
      @proof_codes.numof(lengths, 15, 0, t) * 1
  }
}

///|
/// The canonical codes are in canonical order and form a prefix code (RFC
/// 1951 section 3.2.2): when `s` comes before `t`, the codes that start with
/// `s`'s code, scaled to 15 bits, end where `t`'s start or before.
pub fn canonical_order(
  c : FixedArray[Int32],
  lengths : FixedArray[Int32],
  n : Int32,
  s : Int32,
  t : Int32,
) -> Unit where {
  proof_require: order_pre(c, lengths, n, s, t),
  proof_ensure: code_end(c, lengths, s) <= code_start(c, lengths, t),
} {
  if lengths[s] == lengths[t] {
    same_length_order(c, lengths, n, s, t)
  } else {
    code_end_bound(c, lengths, n, s)
    code_start_bound(c, lengths, n, t)
    kraft_upto_grows(c, lengths[s], lengths[t] - 1)
  }
}

///|
/// The canonical codes fit their lengths when Kraft's sum is at most 1: the
/// codes that start with `s`'s code end within the 15-bit code space.
pub fn canonical_fits(
  c : FixedArray[Int32],
  lengths : FixedArray[Int32],
  n : Int32,
  s : Int32,
) -> Unit where {
  proof_require: coded_at(c, lengths, n, s) && @proof_codes.kraft(c) <= 32768,
  proof_ensure: code_end(c, lengths, s) <= 32768,
} {
  code_end_bound(c, lengths, n, s)
  kraft_upto_grows(c, lengths[s], 15)
  kraft_all(c)
}
