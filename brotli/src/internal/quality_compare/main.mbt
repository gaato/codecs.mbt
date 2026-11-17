///|
async fn main {
  let args = @env.args()
  let quality = @string.parse_int(args[1])
  let input = @fs.read_binary(args[2])
  @stdio.stdout.write(@brotli.compress(input, quality~, window_bits=22))
}
