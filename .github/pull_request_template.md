## What changed

What becomes possible or more reliable for an Imp user, and what public
behavior changed. Name the upstream source or paper if one is involved.

## How it was verified

Run `mix check` — it is the ordinary merge signal and it needs no credentials.
Paste the summary line. Run any further gate your change touches
(`mix protocol.check`, `mix package.check`, `mix quality.check`,
`mix dialyzer.check`); `CONTRIBUTING.md` lists them all.

Say what you could not run and why. Provider-backed, research-scale and
benchmark checks need credentials, datasets or spend: they are the
maintainer's to run, and an outside contributor is not expected to.

## Documentation

Update ExDoc, guides or Livebooks alongside a public API change.
