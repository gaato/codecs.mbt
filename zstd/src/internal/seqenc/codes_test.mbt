///|
test "length codes by table and highest bit equal the baseline scan for every block length" {
  for v in 0..<=131072 {
    assert_eq(@seqenc.ll_code(v), @seqenc.length_code(v, @seqenc.ll_base))
    assert_eq(@seqenc.ml_code(v), @seqenc.length_code(v, @seqenc.ml_base))
  }
}
