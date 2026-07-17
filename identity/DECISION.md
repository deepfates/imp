# Identity Decision

Decision and cutover date: 2026-07-14

The owner selected **Imp** as the final project identity and accepted the
qualified coexistence risk recorded in the archived finalist review. The
greenfield code, documentation, package metadata, and private GitHub repository
have completed the hard cutover from the former working identity. The Hex name
`imp` was available when checked; no package publication is claimed here.

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

Live code and new outputs use only the final forms. There is no parallel legacy
module hierarchy or deprecated command surface.

## Historical Boundary

Raw research, append-only events, and frozen benchmark artifacts retain the
names and bytes under which they were produced. Readers normalize legacy
serialized fields only at explicit, tested compatibility boundaries; writers
emit only Imp identities. See `docs/internal/IDENTITY_COMPATIBILITY.md` for the artifact
migration policy.

Other unrelated software projects using the ordinary word `Imp` are an
accepted coexistence risk. Registry observations are not trademark clearance,
and legal review remains outside this codebase's claims.

## Research Archive

The complete naming engine and DSEx-to-Imp case study are preserved in the
private [`deepfates/naming-lab`](https://github.com/deepfates/naming-lab)
repository at immutable commit
[`2b7c3074ee6c7c9b4811548c9f3e4b8d502b8ac7`](https://github.com/deepfates/naming-lab/tree/2b7c3074ee6c7c9b4811548c9f3e4b8d502b8ac7).
That archive records source snapshot
`37f22f2d467f9bca987914786944f1abbe3f689d` and the complete old-to-new commit
mapping.

Verified archive anchors:

| Artifact | SHA-256 |
| --- | --- |
| `provenance/extraction-manifest.json` | `e22156d8554d44871211b119ecbc7bdffde3a0bf3c21850b71f8c838e3e522e2` |
| `case_studies/imp/study.json` | `204072a71b045da3b1f8bf8cfe46979dd7c23afc901668d56ce6f3b24879b95c` |
| `identity/atlas.json` | `98e0fb83adfdea60777f29c10ac340863b87e776c2d80feff632b322f5a6639d` |

A fresh clone at that commit passed 80 tests, strict Credo, Hex security audit,
the 110-path extraction verifier, and all checks for both preserved studies.
