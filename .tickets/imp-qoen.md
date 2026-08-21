---
id: imp-qoen
status: open
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
