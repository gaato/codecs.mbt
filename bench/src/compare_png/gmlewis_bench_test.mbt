///|
test "gmlewis" (b : @bench.T) {
  let (plain, interlaced, want) = images()
  assert_true(gives("gmlewis", plain, want))
  assert_true(gives("gmlewis", interlaced, want))
  b.bench(name="gmlewis png 512x384 rgb8", () => {
    b.keep(native("gmlewis", plain))
  })
  b.bench(name="gmlewis png 512x384 rgb8 adam7", () => {
    b.keep(native("gmlewis", interlaced))
  })
}
