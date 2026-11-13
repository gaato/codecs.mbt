///|
/// Owns exactly the tables required by the selected strategy.
priv enum Matcher {
  Fast(@matcher.Fast)
  Dfast(@matcher.Dfast)
  Lazy(@matcher.Lazy)
}

///|
fn Matcher::new(params : Params) -> Matcher {
  if params.strategy is Fast {
    Fast(
      @matcher.Fast(
        hash_log=params.hash_log,
        min_match=params.min_match,
        target_length=params.target_length,
        window_log=params.window_log,
      ),
    )
  } else if params.strategy is Dfast {
    Dfast(
      @matcher.Dfast(
        hash_log=params.hash_log,
        chain_log=params.chain_log,
        min_match=params.min_match,
        window_log=params.window_log,
      ),
    )
  } else {
    Lazy(
      @matcher.Lazy(
        hash_log=params.hash_log,
        chain_log=params.chain_log,
        min_match=params.min_match,
        search_log=params.search_log,
        depth=match params.strategy {
          Greedy => 0
          Lazy => 1
          _ => 2
        },
        window_log=params.window_log,
      ),
    )
  }
}

///|
fn Matcher::reset(self : Matcher) -> Unit {
  match self {
    Fast(f) => f.reset()
    Dfast(f) => f.reset()
    Lazy(f) => f.reset()
  }
}

///|
fn Matcher::memory_usage(self : Matcher) -> Int32 {
  match self {
    Fast(f) => f.memory_usage()
    Dfast(f) => f.memory_usage()
    Lazy(f) => f.memory_usage()
  }
}

///|
fn Matcher::find(
  self : Matcher,
  input : FixedArray[Byte],
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  match self {
    Fast(f) => f.find(input, n, repeats, block)
    Dfast(f) => f.find(input, n, repeats, block)
    Lazy(f) => f.find(input, n, repeats, block)
  }
}
