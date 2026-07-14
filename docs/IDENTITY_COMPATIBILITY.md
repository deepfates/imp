# Identity Compatibility

Imp is a greenfield product with one current identity. It does not expose a
legacy DSEx namespace, application, Mix task family, configuration prefix, or
writer format.

The compatibility boundary exists only for persisted programs, optimizer
artifacts, checksummed benchmark evidence, and pinned differential fixtures
created before the Imp cutover. Readers verify original envelopes and checksums
before translating an enumerated set of historical tags, runtime keys, and case
identifiers in memory. Unknown forms fail through the current strict validators.

`Imp.Persistence.Legacy` owns these translations. New writers emit only Imp
identities. Frozen evidence is never rewritten to make a current-name audit
pass, because doing so would invalidate its provenance or checksum. Tests cover
both successful migration and collision or tampering rejection.

This boundary may shrink when an old artifact class is no longer supported. It
must not expand into aliases for current source code or public APIs.
