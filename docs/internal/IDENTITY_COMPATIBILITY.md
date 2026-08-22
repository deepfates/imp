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

## Maintainer Check

The clean-room package contract proves that a consumer sees `app: :imp` and
loads the expected OTP application callback tuple. Ordinary code review and
search are sufficient for historical names; a 445-entry token allowlist was
more likely to bless residue than catch a user-visible regression.
