// Generated from parts/proof_codes/codes_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// The proof steps compute nothing: running them shows that they return,
/// whatever they are given, as the programs that call them rely on.
test "the proof steps run and do nothing" {
  let c = FixedArray::make(16, 0)
  let lengths : FixedArray[Int32] = [1, 2, 2, 0]
  for l in 0..<15 {
    @proof_codes.space_left_step(c, l)
  }
  @proof_codes.kraft_space(c)
  @proof_codes.kraft_one_bit(c)
  @proof_codes.reverse_facts(0)
  @proof_codes.first_code_one(c)
  for l in 1..<15 {
    @proof_codes.first_code_step(c, l)
  }
  for i in 0..<4 {
    @proof_codes.count_step(lengths, i)
    @proof_codes.count_others(lengths, i)
    @proof_codes.count_grows(lengths, 2, 0, i)
  }
  inspect(c.iter().all(x => x == 0), content="true")
}
