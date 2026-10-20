///|
/// The inverse move-to-front transform as section 7.3 describes it, over a
/// list: each value is the index of an entry, which moves to the front.
fn reference_inverse_mtf(values : Array[Int32]) -> Array[Int32] {
  let list = Array::makei(256, i => i)
  values.map(v => {
    let entry = list.remove(v)
    list.insert(0, entry)
    entry
  })
}

///|
/// The forward transform: each value becomes its index in the list, and
/// moves to the front.
fn move_to_front(values : Array[Int32]) -> Array[Int32] {
  let list = Array::makei(256, i => i)
  values.map(v => {
    let index = list.search(v).unwrap()
    list.remove(index) |> ignore
    list.insert(0, v)
    index
  })
}

///|
fn inverse_mtf(values : Array[Int32]) -> Array[Int32] raise {
  let n = values.length()
  // A sentinel after the values: the transform must not write it.
  let buf = FixedArray::make(n + 1, b'\xab')
  for i, v in values {
    buf[i] = v.to_byte()
  }
  @rules.inverse_move_to_front(buf, n)
  assert_eq(buf[n], b'\xab')
  [
    for i in 0..<n => buf[i].to_int()
  ]
}

///|
/// Every sequence of length `n` over 0..<`k`.
fn sequences(n : Int32, k : Int32) -> Array[Array[Int32]] {
  if n == 0 {
    return [[]]
  }
  let out = []
  for s in sequences(n - 1, k) {
    for v in 0..<k {
      out.push([..s, v])
    }
  }
  out
}

///|
/// Every permutation of 0..<`n`.
fn permutations(n : Int32) -> Array[Array[Int32]] {
  if n == 0 {
    return [[]]
  }
  let out = []
  for p in permutations(n - 1) {
    for i in 0..<=p.length() {
      let q = p.copy()
      q.insert(i, n - 1)
      out.push(q)
    }
  }
  out
}

///|
test "inverse move-to-front agrees with RFC 7932 on every short sequence" {
  for n in 0..<=5 {
    for s in sequences(n, 6) {
      let out = inverse_mtf(s)
      assert_eq(out, reference_inverse_mtf(s))
      // A bijection: the forward transform undoes it.
      assert_eq(move_to_front(out), s)
    }
  }
}

///|
test "inverse move-to-front keeps prefixes and permutations" {
  let perms = permutations(6)
  assert_eq(perms.length(), 720)
  let images : Map[Int32, Unit] = Map([])
  for p in perms {
    let out = inverse_mtf(p)
    assert_eq(out, reference_inverse_mtf(p))
    // Each prefix maps as it would alone: the transform reads left to right.
    for k in 0..<=6 {
      assert_eq(inverse_mtf(p[:k].to_owned()), out[:k].to_owned())
    }
    // Distinct inputs map to distinct outputs.
    let key = out.fold(init=0, (k, v) => k * 6 + v)
    assert_false(images.contains(key))
    images[key] = ()
  }
}

///|
test "inverse move-to-front over whole bytes, as long as a context map" {
  let mut seed = 12345
  let values = Array::makei(64 * 256, _ => {
    seed = (seed * 1103515245 + 12345) & 0x7fff_ffff
    // Mostly small indices, as real context maps have, and some large.
    let r = seed >> 8
    if (r & 7) == 0 {
      r & 255
    } else {
      r & 3
    }
  })
  let out = inverse_mtf(values)
  assert_eq(out, reference_inverse_mtf(values))
  assert_eq(move_to_front(out), values)
}
