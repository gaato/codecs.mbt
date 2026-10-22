# Resource bounds

What the PNG decoder holds, and what keeps each structure from growing
without limit. The rule: **every structure that grows with the input is
listed here with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over images that push it.
`scripts/bounds_check.mbtx`, run by `scripts/gates.mbtx`, enforces the
naming; whether a named test really reaches the bound is checked in review.

The decoder is not written yet, so it holds nothing; the table gains a row
for each structure it comes to hold.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
