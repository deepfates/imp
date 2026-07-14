# Identity Decision

Decision date: 2026-07-14

The owner selects **Imp** as the final project identity and accepts the qualified
coexistence risk documented in `reports/imp-finalist-review.md`. This authorizes
a hard pre-release cutover from the working DSEx identity.

On the decision date, Hex reported no package named `imp` and GitHub did not
resolve `deepfates/imp`. These are dated mechanical availability observations,
not reservations; repository rename and package publication remain later
execution steps.

## Naming Contract

| Surface | Final form |
| --- | --- |
| Brand | `Imp` |
| Descriptor | `Declarative self-improving Elixir` |
| Elixir module root | `Imp` |
| Hex package | `imp` |
| OTP application | `:imp` |
| Mix task prefix | `mix imp.*` |
| Telemetry root | `[:imp, ...]` |
| Environment prefix | `IMP_*` |
| Artifact prefixes | `imp_*`, `imp-*` |
| Repository coordinate | `deepfates/imp` |

Live code and new outputs use only the final forms. This is a greenfield hard
cutover: no parallel `DSEx` module hierarchy or deprecated command surface is
introduced.

## Historical Boundary

Raw identity research, append-only identity events, and frozen benchmark
artifacts retain the names and bytes under which they were produced. Readers
may normalize legacy serialized fields at explicit, tested input boundaries;
writers never emit the old identity. Historical prose may use `DSEx` only when
identifying the former working name or the implementation that produced a
frozen result.

This record authorizes implementation. Other unrelated software projects using
the ordinary word `Imp` are accepted as non-blocking by the owner. This record
does not claim that the code, repository, or package rename has already happened.
