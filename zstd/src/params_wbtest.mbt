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

///|
fn complete_row(p : Params) -> String {
  let name = match p.strategy {
    Fast => "Fast"
    Dfast => "Dfast"
    Greedy => "Greedy"
    Lazy => "Lazy"
    Lazy2 => "Lazy2"
    Btlazy2 => "Btlazy2"
    Btopt => "Btopt"
  }
  "\{p.window_log}/\{p.chain_log}/\{p.hash_log}/\{p.search_log}/\{p.min_match}/\{p.target_length}/\{name}"
}

///|
test "effective strategy rows preserve all numeric parameters including tree rows" {
  let rows = [
    for size in [None, Some(16384L), Some(131072L), Some(262144L)] => {
      [
        for level in 1..<=12 => encoder_params(level, size)
      ]
    }
  ]
  let lines = rows.map(ps => ps.map(complete_row).join(" "))
  inspect(
    lines.join("\n"),
    content=(
      #|19/13/14/1/7/0/Fast 20/15/16/1/6/0/Fast 21/16/17/1/5/0/Dfast 21/18/18/1/5/0/Dfast 21/18/19/3/5/2/Greedy 21/18/19/3/5/4/Lazy 21/19/20/4/5/8/Lazy 21/19/20/4/5/16/Lazy2 22/20/21/4/5/16/Lazy2 22/21/22/5/5/16/Lazy2 22/21/22/6/5/16/Lazy2 22/22/23/6/5/32/Lazy2
      #|14/14/15/1/5/0/Fast 14/14/15/1/4/0/Fast 14/14/15/2/4/0/Dfast 14/14/14/4/4/2/Greedy 14/14/14/3/4/4/Lazy 14/14/14/4/4/8/Lazy2 14/14/14/6/4/8/Lazy2 14/14/14/8/4/8/Lazy2 14/15/14/5/4/8/Lazy2 14/15/14/9/4/8/Lazy2 14/15/14/3/4/12/Lazy2 14/15/14/4/3/24/Lazy2
      #|17/12/13/1/6/0/Fast 17/13/15/1/5/0/Fast 17/15/16/2/5/0/Dfast 17/17/17/2/4/0/Dfast 17/16/17/3/4/2/Greedy 17/16/17/3/4/4/Lazy 17/16/17/3/4/8/Lazy2 17/16/17/4/4/8/Lazy2 17/16/17/5/4/8/Lazy2 17/16/17/6/4/8/Lazy2 17/17/17/5/4/8/Lazy2 17/18/17/7/4/12/Lazy2
      #|18/13/14/1/6/0/Fast 18/14/14/1/5/0/Dfast 18/16/16/1/4/0/Dfast 18/16/17/3/5/2/Greedy 18/17/18/5/5/2/Greedy 18/18/19/3/5/4/Lazy 18/18/19/4/4/4/Lazy 18/18/19/4/4/8/Lazy2 18/18/19/5/4/8/Lazy2 18/18/19/6/4/8/Lazy2 18/18/19/5/4/12/Lazy2 18/19/19/7/4/12/Lazy2
    ),
  )
  for size in [None, Some(1000L), Some(100000L), Some(200000L), Some(400000L)] {
    for level in 1..<=12 {
      let p = params_for(level, size)
      let expected = match p.strategy {
        Btlazy2 | Btopt => { ..p, strategy: Lazy2, }
        _ => p
      }
      assert_eq(
        complete_row(encoder_params(level, size)),
        complete_row(expected),
      )
    }
  }
}
