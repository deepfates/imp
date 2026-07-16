# Identity Cutover

Imp is a greenfield product with one current identity. Its package and active
runtime paths accept only canonical Imp namespaces, configuration prefixes,
wire tags, and artifact envelopes.

There is no compatibility reader for pre-cutover persisted programs, optimizer
artifacts, manifests, or fixtures. Readers verify canonical envelopes and
checksums, and unknown or non-canonical forms fail through the current strict
validators. Writers emit only canonical Imp data.

Historical evidence is not rewritten merely to make a current-name audit pass,
because that would invalidate its provenance or checksum. Generic historical
schema migrations remain supported where they are part of a current Imp
contract; they do not translate the old project identity.

This cutover is intentionally final for the greenfield package. It must not
expand into aliases for current source code, persisted data, or public APIs.

## Maintainer Audit

The source checkout keeps this policy executable with:

```sh
mix legacy_identity.check
```

The check reads the tracked tree with an Elixir path policy. It scans the live
and package-facing `lib/`, deployment, Livebook, documentation, README, and
release surfaces for obsolete identity tokens. Only the audit implementation,
its entrypoint, and immutable historical benchmark/provenance paths are
allowlisted. A new token in a product surface fails the check; the focused
test also supplies a controlled live-source fixture to prove that behavior.

The package contract separately proves that a clean consumer sees `app: :imp`
and loads the expected OTP application callback tuple. The current OTP identity
is therefore checked at both the source boundary and the package boundary.
