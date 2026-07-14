# Repository Rename Surface Audit

Snapshot: 2026-07-13

## Conclusion

The eventual rename is a coordinated API and operational-contract migration,
not a documentation substitution. The final identity decision must define the
complete code nomenclature before implementation begins.

A clean pre-release rename is the default recommendation. The repository is
private, has no Git tags, and `dsex` has no public Hex package record as of this
snapshot. Maintaining a second tree of deprecated `DSEx` module aliases would
add a large public surface without protecting an observed released user base.
Compatibility should be limited to persisted artifacts or frozen benchmark
evidence that the repository deliberately continues to read.

This audit does not rank names. It makes the consequences of the eventual
decision explicit.

## Current Scale

| Surface | Observed extent |
| --- | ---: |
| Files containing `DSEx`, `dsex`, or `DSEX` | 665 |
| `DSEx` module definitions | 324 across 272 files |
| Files under `lib/dsex/` | 271 |
| `Mix.Tasks.Dsex` definitions | 53 across 51 files |
| Test files referencing the current identity | 212 |
| Distinct `DSEX_*` environment variables | 42 |
| Source lines containing `[:dsex, ...]` telemetry events | 92 |

The raw count includes immutable identity research and historical evidence that
should retain the name under which it was produced. It is therefore a migration
inventory, not a target for unqualified global replacement.

## Identity Grammar To Freeze

The selected identity must be projected into every row before files are
renamed. A master brand and code name may differ, but any difference must be an
intentional architecture rather than an accident of implementation.

| Layer | Current projection | Required decision |
| --- | --- | --- |
| Display brand | `DSEx` | Product and documentation name |
| Elixir module root | `DSEx` | Valid, readable CamelCase module root |
| Hex package | `dsex` | Exact package name |
| OTP application and config | `:dsex` | Atom used by Mix and runtime config |
| Mix task namespace | `dsex.*` | Shell-facing command prefix |
| Telemetry namespace | `[:dsex, ...]` | Stable event-family root |
| Environment prefix | `DSEX_*` | Stable deployment contract |
| Repository slug | `deepfates/dsex` | GitHub and source URL |
| Artifact and benchmark prefix | `dsex_*`, `dsex-*` | New-output field and file convention |
| Example application | `DSExDeployment`, `:dsex_deployment` | Reference deployment identity |

The decision record should also state the pronunciation, expansion or category
descriptor, capitalization, possessive form, and whether the brand may name a
future hosted product or organization.

## Required Migration Layers

### Package And Repository

- Rename `DSEx.MixProject`, `:dsex`, package metadata, source links, ExDoc main
  page and module filters, release archive patterns, and repository references.
- Rename the GitHub repository only after the replacement slug has passed the
  final namespace and legal-risk screen.
- Re-run the clean-room package build against the renamed package contents.

### Public API And Source Layout

- Rename the module root and all public and internal module references.
- Move `lib/dsex.ex`, `lib/dsex/`, corresponding test paths, doctests, types,
  examples, and documentation references together.
- Rename the 53 Mix task modules, their files, aliases, help text, and every
  invocation in scripts, CI, documentation, and evidence tooling.

### Runtime And Operations

- Rename the OTP application/config atom, application callback, process names,
  context keys, cache keys, and other product-prefixed atoms.
- Rename the telemetry root as one event family and update handler attachment,
  documentation, tests, and dashboards in the same change.
- Rename all 42 environment variables and update the deployment example,
  provider configuration, benchmark runners, scripts, and operational docs.
- Review CLI options, temporary-directory prefixes, provider paths, log fields,
  serialized markers such as `__dsex_type__`, and artifact filenames. These
  strings are contracts when another process or persisted file can observe
  them, even if they look internal.

### Examples, Research, And Automation

- Update all examples, five livebooks, the deployment reference application,
  benchmark code, scripts, CI templates, security guidance, and contributor
  instructions.
- Rename current benchmark labels and new-output fields without changing the
  meaning of comparisons against DSPy.
- Update current identity reports to describe the former working name while
  retaining the raw observations on which their conclusions depend.

## Historical Evidence Policy

Do not bulk-replace the immutable identity corpus. Accepted `identity/inbox/`
portfolios and append-only registry, enrichment, assessment, flag, and dissent
events are evidence about strings observed at a particular time. Rewriting them
would alter provenance and invalidate source hashes.

Likewise, previously generated benchmark results should remain faithful to the
implementation identity and field names present when they ran. New runs should
emit the new identity. Readers that must aggregate both generations should
normalize legacy `dsex_*` fields at the input boundary and test that behavior;
they should not perpetuate the old name through new outputs.

Allowed post-rename occurrences of the old identity must therefore be explicit:

- immutable identity records and their integrity manifests;
- reports or changelog prose that deliberately says "formerly DSEx";
- frozen benchmark outputs;
- narrowly scoped compatibility readers and fixtures for persisted artifacts.

Everything else is a migration defect.

## Compatibility Decision

Use a hard rename for modules, package, OTP app, tasks, config, telemetry, and
environment variables. Do not introduce a parallel deprecated module hierarchy
unless release evidence discovered before implementation demonstrates real
external users who cannot migrate atomically.

Use targeted backward readers only where old serialized artifacts or benchmark
results are intentionally supported. Writers must emit only the new schema.
Version or tag the artifact format where a prefixed key cannot be changed
without ambiguity.

## Execution Order

1. Record the final identity grammar and exact namespace checks.
2. Rename the Mix project, package, OTP app, module tree, tests, and Mix tasks
   in one compiling change.
3. Rename config, telemetry, environment, process, CLI, and filesystem
   contracts; add focused contract tests.
4. Migrate artifact and benchmark writers, then add only the required legacy
   readers and fixtures.
5. Update examples, livebooks, scripts, CI, package metadata, and current docs.
6. Rename the private GitHub repository and update remote and source links.
7. Regenerate derived documentation and identity views, preserving raw inputs.
8. Run the full verification set and audit every remaining old-name occurrence.

## Verification Gates

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix public_surface.check`
- `mix production.check`
- `mix quality.check`
- `mix protocol.check`
- `mix livebook.execute.check`
- deployment-example tests using the renamed source-path environment variable
- package clean-room installation and smoke execution under the new app name
- benchmark catalog and representative evidence tasks under the new task prefix
- documentation build with valid local and repository links
- repository-wide old-token scan, with every remaining occurrence matching the
  historical-evidence allowlist above

The rename is complete only when a fresh consumer can install, configure,
compile, call, observe, package, and run the project using only the new identity,
while intentionally retained historical artifacts still verify and load.
