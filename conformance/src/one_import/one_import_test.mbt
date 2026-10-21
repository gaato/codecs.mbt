///|
/// Raises what `@gzip.decompress` makes of `input`, through a signature that
/// names the error by gaato/codec_bytes.
fn gunzip(input : Bytes) -> Bytes raise @codec_bytes.CodecError {
  @gzip.decompress(input)
}

///|
/// The limit an error was about, named by gaato/codec_bytes.
fn limit_of(kind : @codec_bytes.ErrorKind) -> @codec_bytes.Limit? {
  match kind {
    LimitExceeded(limit) => Some(limit)
    _ => None
  }
}

///|
test "the error types are named and matched through gaato/codec_bytes" {
  // Unqualified constructors, where the error's type is known.
  let kind = try gunzip(b"\x1f\x8b") catch {
    CodecError(Truncated, _) => "truncated"
    CodecError(_, _) => "other"
  } noraise {
    _ => "decoded"
  }
  inspect(kind, content="truncated")
  // Qualified by its type, where it is not.
  let erased : (Bytes) -> Unit raise = input => ignore(gunzip(input))
  let kind = try erased(b"x") catch {
    @codec_bytes.CodecError::CodecError(kind, _) => Some(kind)
    _ => None
  } noraise {
    _ => None
  }
  assert_true(kind is Some(@codec_bytes.ErrorKind::Truncated))
  // The limit's types.
  let gz = @gzip.compress(b"hello")
  let limit = try @gzip.decompress(gz, max_output=2) catch {
    CodecError(kind, _) => limit_of(kind)
  } noraise {
    _ => None
  }
  guard limit is Some(limit) else { fail("not a limit") }
  assert_true(limit.resource is @codec_bytes.Resource::Output)
  assert_eq(limit.limit, 2)
}
