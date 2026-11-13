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
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  match self {
    Fast(f) => f.find_buffered(n, repeats, block)
    Dfast(f) => f.find_buffered(n, repeats, block)
    Lazy(f) => f.find_buffered(n, repeats, block)
  }
}

///|
fn Matcher::history(self : Matcher) -> @matcher.History {
  match self {
    Fast(f) => f.history()
    Dfast(f) => f.history()
    Lazy(f) => f.history()
  }
}

///|
fn Matcher::prepare(self : Matcher, block_max : Int32) -> Unit {
  match self {
    Fast(f) => f.prepare(block_max)
    Dfast(f) => f.prepare(block_max)
    Lazy(f) => f.prepare(block_max)
  }
}

///|
fn Matcher::finish(self : Matcher) -> Unit {
  self.history().finish_block()
}
