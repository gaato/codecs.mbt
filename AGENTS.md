## Documentation

- A published module's README is for people deciding whether and how to use
  it: what it is, install, a working example, what a caller must know
  (limits, errors), links. mooncakes.io renders it as the module page, so
  design rationale, test and proof procedures, CI details, benchmarks and
  version-pinned facts go to the module's ledgers (PROOFS.md,
  TEST_COVERAGE.md, RESOURCE_BOUNDS.md), its `docs/`, ARCHITECTURE.md or the
  CHANGELOG, linked from the README's `## Links`.
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
