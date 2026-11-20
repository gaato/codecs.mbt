## Documentation

- A published module's README is for people deciding whether and how to use
  it: what it is, install, a working example, what a caller must know
  (limits, errors), links. mooncakes.io renders it as the module page, so
  design rationale, test and proof procedures, CI details, benchmarks and
  version-pinned facts go to the module's ledgers (PROOFS.md,
  TEST_COVERAGE.md, RESOURCE_BOUNDS.md), its `docs/`, ARCHITECTURE.md
  (how the repository is laid out), `docs/decisions.md` (why, and what was
  left out) or the CHANGELOG, linked from the README's `## Links`.
- Edit a README in `<module>/src/overview.mbt.md`; `<module>/README.md` is a
  symbolic link to it. The examples in it compile as the package's tests, so
  a stale example fails `moon test`, and mooncakes.io would show a second
  copy if the root package held a README of its own.
- Run `moon run scripts/docs_audit.mbtx --self-test` after changing
  documentation or public declarations; the gates and CI run it too.
  Published modules and generated sources are listed in
  `scripts/docs_audit.json`, deliberate exceptions in
  `scripts/docs_audit.allow`, each with its reason. When a module takes a
  new copy of `parts/` (`copies` in `scripts/modules.json`), add its
  directory to `generated` too: the copies' first line does not say
  `DO NOT EDIT`, so the audit would otherwise ask for doc comments in a file
  that is overwritten from `parts/`.
- `scripts/docs_audit.mbtx` is the same file in every gaato MoonBit
  repository, so that every module page reads to one standard. Copy it from
  gaato/discord.mbt rather than editing it here; a change belongs in all of
  them at once.
- A module README is also read raw by coding agents in a user's
  `.mooncakes/`. They copy its examples, take every sentence literally, fill
  what it leaves out with guesses, and read the published text until the next
  release, while the modules it might mention change and get renamed.

## Speed work

- Speed work keeps every encoder's output byte for byte, and every error's
  kind and position: the SHA-256 pins and ratio tables hold the bytes, and
  `docs/decisions.md` ("Encoders keep their output") says how a faster,
  different output would be added instead.
- Every unchecked access says why it is in bounds, at the access or on the
  helper it goes through. Nothing checks it at run time on native and Wasm,
  where a wrong index silently reads or corrupts memory; JS and Wasm GC
  still trap. Compare bounds that can come near the largest `Int` as
  differences (`n - i >= 8`, not `i + 8 <= n`), so the index cannot wrap
  past the check.
- Wide reads (four or eight bytes) and `@v128` go behind
  `#cfg(any(target="native", target="wasm"))`; the other targets keep a
  byte loop. SIMD goes in a package of its own beside the plain or proved
  reference, with tests comparing the two at every alignment, because
  `moon prove` refuses SIMD operations and `@v128` is experimental. A
  proved function made faster keeps its proof.
- A change helps one backend and slows another more often than not, so
  measure it on all four targets, with `taskset` as bench/README.md says,
  and, on Wasm, in the format's own benchmark binary and the combined one.
  Single runs swing by about 2%: rerun a case that comes out more than 2%
  slower as five alternating runs per side. Keep a change only on the
  targets where nothing gets more than 2% slower, with `#cfg` and a comment
  giving the number, and add what was left out to `docs/decisions.md`.

## Navigating with `moon ide`

- Every copy of a part is a separate symbol, so `find-references` and
  `workspace-symbols` list one hit per module that copies it. Read the one
  in `parts/` and drop the `internal/` copies (`copies` in
  `scripts/modules.json` lists them), along with `.mooncakes` and tests.
- Do not rename a part's symbol with `moon ide rename --apply`. Each copy is
  a separate symbol, so it renames one copy, which `scripts/gen_parts.mbtx`
  then overwrites from `parts/`, or only `parts/`, leaving the modules'
  callers behind. Rename in `parts/`, regenerate, then fix the callers.
- A query takes about 30 seconds and can hold the `_build` lock, so do not
  run it while a benchmark or a timed test runs in the same directory.

## API changes

- When a published function's labelled parameter is renamed or removed, an
  optional one becomes required, or a positional one becomes labelled, keep
  existing calls compiling for one minor release with `#label_migration`
  (`alias=old`, `fill=false`, `fill=true` or `allow_positional=true`) and a
  `msg` naming the new form, and remove the attribute in the next minor
  release. Callers then get a warning instead of a build failure; the
  CHANGELOG still lists the change with its migration note. A renamed or
  removed function keeps a `#deprecated` alias for the same period.
