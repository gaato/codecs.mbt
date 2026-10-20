// The inverse move-to-front transform of context maps (RFC 7932 section
// 7.3).

///|
/// Replaces `values[0..n)` by their inverse move-to-front transform: each
/// value is an index into a list that starts as 0 to 255, and becomes the
/// entry at that index, which then moves to the front of the list. Writes
/// nothing else.
pub fn inverse_move_to_front(values : FixedArray[Byte], n : Int32) -> Unit {
  let mtf = FixedArray::makei(256, i => i.to_byte())
  for i in 0..<n {
    let index = values[i].to_int()
    let value = mtf[index]
    values[i] = value
    for j = index; j > 0; j = j - 1 {
      mtf[j] = mtf[j - 1]
    }
    mtf[0] = value
  }
}
