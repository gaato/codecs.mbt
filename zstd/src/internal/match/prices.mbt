// zstd 1.5.7 zstd_opt.c: integer and fractional prices, adaptive statistics.

///|
priv struct Prices {
  lit : FixedArray[Int32]
  ll : FixedArray[Int32]
  ml : FixedArray[Int32]
  of : FixedArray[Int32]
  level : Int32
  mut lit_sum : Int32
  mut ll_sum : Int32
  mut ml_sum : Int32
  mut of_sum : Int32
  mut lit_base : Int32
  mut ll_base : Int32
  mut ml_base : Int32
  mut of_base : Int32
  mut predefined : Bool
}

///|
fn Prices::new(enabled : Bool, level : Int32) -> Prices {
  {
    lit: FixedArray::make(if enabled { 256 } else { 0 }, 0),
    ll: FixedArray::make(if enabled { 36 } else { 0 }, 0),
    ml: FixedArray::make(if enabled { 53 } else { 0 }, 0),
    of: FixedArray::make(if enabled { 32 } else { 0 }, 0),
    level,
    lit_sum: 0,
    ll_sum: 0,
    ml_sum: 0,
    of_sum: 0,
    lit_base: 0,
    ll_base: 0,
    ml_base: 0,
    of_base: 0,
    predefined: false,
  }
}

///|
fn Prices::reset(self : Prices) -> Unit {
  self.lit.fill(0)
  self.ll.fill(0)
  self.ml.fill(0)
  self.of.fill(0)
  self.lit_sum = 0
  self.ll_sum = 0
  self.ml_sum = 0
  self.of_sum = 0
}

///|
fn Prices::weight(self : Prices, raw : Int32) -> Int32 {
  let stat = raw + 1
  let hb = 31 - stat.clz()
  (hb << 8) + (if self.level == 2 { stat << 8 >> hb } else { 0 })
}

///|
fn downscale(
  table : FixedArray[Int32],
  shift : Int32,
  base_one : Bool,
) -> Int32 {
  let mut sum = 0
  for i in 0..<table.length() {
    table[i] = (if base_one || table[i] > 0 { 1 } else { 0 }) +
      (table[i] >> shift)
    sum += table[i]
  }
  sum
}

///|
fn scale_stats(table : FixedArray[Int32], log : Int32) -> Int32 {
  let mut sum = 0
  for v in table {
    sum += v
  }
  let factor = sum >> log
  if factor <= 1 {
    sum
  } else {
    downscale(table, 31 - factor.clz(), true)
  }
}

///|
fn Prices::rescale(
  self : Prices,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
) -> Unit {
  self.predefined = false
  if self.ll_sum == 0 {
    self.predefined = end - start <= 8
    self.lit.fill(0)
    for i in start..<end {
      self.lit[data[i].to_int()] += 1
    }
    self.lit_sum = downscale(self.lit, 8, false)
    self.ll.fill(1)
    self.ll[0] = 4
    self.ll[1] = 2
    self.ll_sum = 40
    self.ml.fill(1)
    self.ml_sum = 53
    let base : FixedArray[Int32] = [
      6, 2, 1, 1, 2, 3, 4, 4, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1,
    ]
    self.of_sum = 0
    for i in 0..<32 {
      self.of[i] = base[i]
      self.of_sum += base[i]
    }
  } else {
    self.lit_sum = scale_stats(self.lit, 12)
    self.ll_sum = scale_stats(self.ll, 11)
    self.ml_sum = scale_stats(self.ml, 11)
    self.of_sum = scale_stats(self.of, 11)
  }
  self.set_bases()
}

///|
fn Prices::set_bases(self : Prices) -> Unit {
  self.lit_base = self.weight(self.lit_sum)
  self.ll_base = self.weight(self.ll_sum)
  self.ml_base = self.weight(self.ml_sum)
  self.of_base = self.weight(self.of_sum)
}

///|
fn Prices::literal(self : Prices, b : Byte) -> Int32 {
  if self.predefined {
    6 * 256
  } else {
    self.lit_base - self.weight(self.lit[b.to_int()]).min(self.lit_base - 256)
  }
}

///|
fn Prices::literal_length(self : Prices, length : Int32) -> Int32 {
  if self.predefined {
    return self.weight(length)
  }
  if length == 131072 {
    return 256 + self.literal_length(131071)
  }
  let code = @seqenc.ll_code(length)
  @seqenc.ll_bits[code] * 256 + self.ll_base - self.weight(self.ll[code])
}

///|
fn Prices::match_price(self : Prices, off : Int32, length : Int32) -> Int32 {
  let oc = 31 - off.clz()
  if self.predefined {
    return self.weight(length - 3) + (16 + oc) * 256
  }
  let mc = @seqenc.ml_code(length)
  oc * 256 +
  self.of_base -
  self.weight(self.of[oc]) +
  (if self.level < 2 && oc >= 20 { (oc - 19) * 512 } else { 0 }) +
  @seqenc.ml_bits[mc] * 256 +
  self.ml_base -
  self.weight(self.ml[mc]) +
  256 / 5
}

///|
fn Prices::update(
  self : Prices,
  data : FixedArray[Byte],
  anchor : Int32,
  ll : Int32,
  off : Int32,
  ml : Int32,
) -> Unit {
  for p in anchor..<(anchor + ll) {
    self.lit[data[p].to_int()] += 2
  }
  self.lit_sum += ll * 2
  self.ll[@seqenc.ll_code(ll)] += 1
  self.ll_sum += 1
  self.ml[@seqenc.ml_code(ml)] += 1
  self.ml_sum += 1
  self.of[31 - off.clz()] += 1
  self.of_sum += 1
}

///|
fn Prices::memory_usage(self : Prices) -> Int32 {
  4 *
  (self.lit.length() + self.ll.length() + self.ml.length() + self.of.length())
}
