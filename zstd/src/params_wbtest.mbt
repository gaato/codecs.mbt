///|
test "known sizes adjust tables before the minimum frame window" {
  // ZSTD_getCParams followed by ZSTD_adjustCParams, v1.5.7, no dictionary.
  // Rows pin all twelve levels, including the extra tree cycle bit. Zero
  // uses a known empty source, not the public getCParams zero/unknown alias.
  let sizes = [0L, 64, 65, 1024, 1025, 8192, 8193, 16385, 65536, 262145]
  let actual = sizes.map(size => {
    let rows = Array::makei(12, i => {
      let p = params_for(i + 1, Some(size))
      "\{p.window_log}/\{p.chain_log}/\{p.hash_log}"
    })
    "\{size}: \{rows.join(" ")}"
  })
  inspect(
    actual.join("\n"),
    content=(
      #|0: 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/7/7 10/7/7 10/7/7 10/7/7
      #|64: 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/6/7 10/7/7 10/7/7 10/7/7 10/7/7
      #|65: 10/7/8 10/7/8 10/7/8 10/7/8 10/7/8 10/7/8 10/7/8 10/7/8 10/8/8 10/8/8 10/8/8 10/8/8
      #|1024: 10/10/11 10/10/11 10/10/11 10/10/11 10/10/11 10/10/11 10/10/11 10/10/11 10/11/11 10/11/11 10/11/11 10/11/11
      #|1025: 11/11/12 11/11/12 11/11/12 11/11/12 11/11/12 11/11/12 11/11/12 11/11/12 11/12/12 11/12/12 11/12/12 11/12/12
      #|8192: 13/13/14 13/13/14 13/13/14 13/13/14 13/13/14 13/13/14 13/13/14 13/13/14 13/14/14 13/14/14 13/14/14 13/14/14
      #|8193: 14/14/15 14/14/15 14/14/15 14/14/14 14/14/14 14/14/14 14/14/14 14/14/14 14/15/14 14/15/14 14/15/14 14/15/14
      #|16385: 15/12/13 15/13/15 15/15/16 15/15/16 15/15/16 15/15/16 15/15/16 15/15/16 15/15/16 15/15/16 15/16/16 15/16/16
      #|65536: 16/12/13 16/13/15 16/15/16 16/16/17 16/16/17 16/16/17 16/16/17 16/16/17 16/16/17 16/16/17 16/17/17 16/17/17
      #|262145: 19/13/14 19/15/16 19/16/17 19/18/18 19/18/19 19/18/19 19/19/20 19/19/20 19/19/20 19/19/20 19/19/20 19/19/20
    ),
  )
  // Adjustment cannot increase any selected table or the memory bound.
  for level in 1..<=12 {
    for
      size in [
        0L,
        63,
        64,
        65,
        513,
        1024,
        1025,
        8192,
        8193,
        16384,
        16385,
        65536,
        65537,
        131072,
        131073,
        262144,
        262145,
        1L << 30,
        (1L << 30) + 1,
      ] {
      let p = params_for(level, Some(size))
      let table = (if size <= 262144 { 1 } else { 0 }) +
        (if size <= 131072 { 1 } else { 0 }) +
        (if size <= 16384 { 1 } else { 0 })
      let before = level_tables[table][level - 1]
      assert_true(p.window_log <= before.window_log)
      assert_true(p.hash_log <= before.hash_log)
      assert_true(p.chain_log <= before.chain_log)
      assert_true(
        encoder_memory_bound(params=encoder_params(level, Some(size))) <=
        encoder_memory_bound(),
      )
    }
  }
}
