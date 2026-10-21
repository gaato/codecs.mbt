///|
/// Proof-side unbounded integers (Why3 `int`), so contracts can relate a
/// UInt to an Int under the machine-integer prelude. No runtime values.
/// After moonbit-community/verified libs/mathint, but without the Add/Mul
/// impls: an impl in .mbtp warns (unused or implicit_impl_as_method) and
/// `pub extend` passes `moon check` but fails `moon build`. Use `.plus`,
/// `.times`, `.le`, `.eq`.
#proof_external("int.Int", "int")
priv type MathInt
