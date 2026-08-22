---
id: imp-qoen
status: closed
deps: [imp-pomi]
links: []
created: 2026-08-07T17:08:17Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [release, package]
---
# Freeze a releasable 0.3.0 product candidate

Produce one immutable, installable 0.3.0 candidate whose public program,
evaluation, bounded optimization, Artifact, and fresh OTP operation story has
been exercised from the package. Publication channel remains an explicit owner
decision: tomorrow's release may be a private/source candidate, Git tag, public
repository, or Hex package, but the candidate itself must not depend on
maintainer checkout state or research-only inputs.

## Acceptance Criteria

The exact clean commit and package checksum are recorded; consumer install,
representative live usefulness, Artifact restart/concurrent service, docs,
Livebooks, protocols, quality, Dialyzer, package audit, and publication dry-run
pass at that commit; no Git blob prevents promotion; changelog/version/docs are
coherent; unresolved research surfaces are labeled without weakening product
gates. Tagging, repository visibility, and Hex publication occur only in the
owner-selected release form.


## Notes

**2026-08-07T17:19:00Z**

WIDENED (r3): repo is also private (gh: isPrivate true) and tags stop at v0.2.1 while mix.exs says 0.3.0. The telos front door (cold user installs from Hex) needs: public repo decision, tag, publish. Also: examples/local_* are maintainer-machine-bound evidence rigs (specific Ollama digests, local MLX checkpoints) — label them as such wherever docs reference them so cold readers don't try to run them.

**2026-08-21T03:23:01Z**

Its two declared documentation dependencies are now closed. Current candidate gates are green for fast, package clean-room, docs, executable Livebooks, integration, protocol, quality, and Dialyzer. Keep this release ticket open until the exact clean candidate commit, package digest, and owner-controlled version/tag/publication form are decided.

**2026-08-21T06:11:14Z**

Candidate frozen: source commit dd93ad3888fb02ffbcc034e8f69ad91e06200583; imp-0.3.0.tar SHA-256 bbdd07148750966e0e522031ec8430687becd77de7c4c31ad715f47d1e66fe77. Exact-commit results: production.check 53 doctests + 9 properties + 2,823 tests, zero failures; package contract 14/14; unpacked clean-room compile, separate writer/loader VMs with tamper rejection, OTP release probe, optimize/select/untouched workflow, fresh-process Artifact application, four concurrent service calls, contained failure/cancellation, and 5/5 executable Livebooks passed. integration 9/9, protocol 6/6, live provider 15/15 via recovered OpenRouter route, golden trace 42/42, overhead 11/11, bounded live failure-recovery complete, quality/Hex audit/Dialyzer green, Hex publication dry-run built successfully, product dashboard profile_ready true. Reachable unpublished max blob is 7,248,174 bytes; the former 608 MB corpus blob is absent. Repository remains private; Hex reports no package named imp. No push, tag, visibility change, or publish performed. Owner release-form choice remains the only open acceptance boundary.

**2026-08-22T13:39:00Z**

Closed as the bounded candidate-freeze milestone, not as completion or publication of the larger product. The exact clean source commit dd93ad3888fb02ffbcc034e8f69ad91e06200583 and package SHA-256 bbdd07148750966e0e522031ec8430687becd77de7c4c31ad715f47d1e66fe77 satisfied this ticket's package, clean-consumer, operational, and candidate-gate acceptance. The owner has since ratified a larger release objective: finish the stable DSPy delta, contemporary OA/Ax product audit, natural retained lifecycle for every advertised optimizer, realistic composed multi-provider operation, adversarial cold consumption, and bounded representative live comparisons. Those capabilities are owned by imp-yme4 and its new dependency chain; reopening this already-achieved freeze milestone would conflate a predecessor receipt with the final release.
