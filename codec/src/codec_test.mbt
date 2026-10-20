///|
fn refuse(err : @codec.CodecError) -> Unit raise @codec.CodecError {
  raise err
}

///|
test "an error carries its kind and message" {
  let err = @codec.CodecError(
    LimitExceeded({
      resource: Memory,
      needed: Some(1UL << 30),
      limit: 1UL << 27,
    }),
    "the frame needs a 1 GiB window",
  )
  assert_true(err.kind() is LimitExceeded({ resource: Memory, .. }))
  try refuse(err) catch {
    CodecError(kind, message) => {
      assert_true(kind is LimitExceeded(_))
      assert_eq(message, "the frame needs a 1 GiB window")
    }
  } noraise {
    _ => fail("not raised")
  }
}
