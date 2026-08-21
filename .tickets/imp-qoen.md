---
id: imp-qoen
status: open
deps: [imp-86as, imp-4er4]
links: []
created: 2026-08-07T17:08:17Z
type: feature
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [release, package]
---
# Hex publication readiness for 0.3.0

Not on Hex; livebook standalone fallback (Mix.install {:imp, "~> 0.3.0"}) cannot resolve by its own admission; adopters cannot install without cloning and pinning a commit. Publication is an explicit owner action — this ticket tracks readiness, not the act.

## Acceptance Criteria

Tag/changelog/docs coherent for 0.3.0; hex.publish dry-run clean; livebook fallback resolves post-publication.


## Notes

**2026-08-07T17:19:00Z**

WIDENED (r3): repo is also private (gh: isPrivate true) and tags stop at v0.2.1 while mix.exs says 0.3.0. The telos front door (cold user installs from Hex) needs: public repo decision, tag, publish. Also: examples/local_* are maintainer-machine-bound evidence rigs (specific Ollama digests, local MLX checkpoints) — label them as such wherever docs reference them so cold readers don't try to run them.

**2026-08-21T03:23:01Z**

Its two declared documentation dependencies are now closed. Current candidate gates are green for fast, package clean-room, docs, executable Livebooks, integration, protocol, quality, and Dialyzer. Keep this release ticket open until the exact clean candidate commit, package digest, and owner-controlled version/tag/publication form are decided.
