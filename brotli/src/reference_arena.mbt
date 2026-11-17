// Share the existing HQ arena slot: quality 4 keeps its original object layout.
// Each reference family allocates only the variant it actually uses.

///|
priv enum EncoderArena {
  Hq(HqTree)
  Low(LowArena)
}

///|
priv struct LowArena {
  mut fragment : FragmentArena?
  mut quick : QuickHasher?
  mut tables : LowTables?
}

///|
fn Encoder::hq_tree(self : Encoder) -> HqTree? {
  match self.arena {
    Some(Hq(h)) => Some(h)
    _ => None
  }
}

///|
fn Encoder::low_arena(self : Encoder) -> LowArena {
  match self.arena {
    Some(Low(low)) => low
    _ => {
      let low = { fragment: None, quick: None, tables: None, }
      self.arena = Some(Low(low))
      low
    }
  }
}

///|
fn Encoder::low_memory(self : Encoder) -> Int32 {
  match self.arena {
    Some(Low(a)) =>
      (match a.fragment {
        Some(f) => f.memory_usage()
        None => 0
      }) +
      (match a.quick {
        Some(q) => q.memory_usage()
        None => 0
      }) +
      (match a.tables {
        Some(t) => t.memory_usage()
        None => 0
      })
    _ => 0
  }
}
