# Ax Independent-Implementation Differential

Ax is an independent TypeScript interpretation of declarative language-model
programming. Imp uses it to distinguish portable semantics from accidental
DSPy/Python behavior. Ax is not a scientific authority for Imp algorithms or
effectiveness claims.

The contract pins `@ax-llm/ax` `23.0.0` at Git commit
`eb5835e54ba0c5b2fbac380daed1cb87faeefd5e`. The npm tarball must match the
checked SHA-512 integrity value, and
`benchmarks/authority_sources/ax-23.0.0-eb5835e.json` binds the 11 relevant
implementation files by SHA-256.

## Run

Prepare the exact compiled release outside the repository:

```sh
mkdir -p /tmp/imp-ax-23
cd /tmp/imp-ax-23
npm pack @ax-llm/ax@23.0.0
tar -xzf ax-llm-ax-23.0.0.tgz
cd package
npm install --no-save --ignore-scripts --no-audit --no-fund @opentelemetry/api@1.9.0
```

Run the clean provider-free differential from the repository root:

```sh
mix imp.benchmark.ax_contract \
  --ax-package-dir /tmp/imp-ax-23/package \
  --ax-tarball /tmp/imp-ax-23/ax-llm-ax-23.0.0.tgz \
  --out benchmarks/results/ax-contract.json
```

The sidecar makes no provider or network calls. The Mix task verifies the npm
tarball and checks that the executed package entrypoint came from that tarball
before writing a clean Git run envelope that is independently validated before
admission.

## Contract

The six vectors cover typed signature fields, output JSON Schema, optional-field
streaming, tool results and unknown-tool failures, cached/reasoning token usage,
and GEPA component selection state.

Four semantics match after normalization. Two are intentional native
differences:

- Ax exposes unknown tools as retryable validation errors. Imp returns a
  structured fail-fast error through its policy and trace boundary.
- Ax includes a stagnation-weighted component bandit. Imp provides
  deterministic round-robin/all policies and a BEAM callback contract for
  custom selectors.

These differences remain visible in every artifact. A complete contract does
not convert them into Ax parity or an optimizer-effectiveness claim.
