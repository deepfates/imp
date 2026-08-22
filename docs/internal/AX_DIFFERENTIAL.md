# Ax Independent-Implementation Differential

Ax is an independent TypeScript interpretation of declarative language-model
programming. Imp uses it to distinguish portable semantics from accidental
DSPy/Python behavior. Ax is not a scientific authority for Imp algorithms or
effectiveness claims.

The executable provider-free contract pins historical `@ax-llm/ax` `23.0.0` at Git commit
`eb5835e54ba0c5b2fbac380daed1cb87faeefd5e`. The npm tarball must match the
checked SHA-512 integrity value, and
`benchmarks/authority_sources/ax-23.0.0-eb5835e.json` binds the 11 relevant
implementation files by SHA-256.

The product-semantic audit is separately pinned to the current npm release,
`@ax-llm/ax` `24.0.4`, whose registry `gitHead` is
`a366e49759bd596c8217eca91dfdc9dd8382835d`. Its tarball has SHA-256
`48f56c094f7c9359434417cfa4de5bbd8dd1294191fd08466bda915852741695`
and npm integrity
`sha512-AI47e4lzihZpBvXaFvmavTXYvVU40r5sskAE59M4RdgJxO1OcChiQkFrwBk+PQ40cIdqPIaY5fG1V9N+rHF+og==`.
The relevant bundled primary documentation is content-bound here:

| Tarball path | SHA-256 | Product question |
| --- | --- | --- |
| `package/skills/ax-agent-optimize.md` | `6c3b2f673a328a4e65727c2247ebb4d840d3b739405c0d6e6fdd22216c8e5467` | action-aware agent optimization and artifacts |
| `package/skills/ax-playbook.md` | `db0f579bbe7fe449c5b066fa9f377a5c4ffa74875b69bd2c26352bfc4abf02e4` | failure-mined evolution, verification, rollback, restore |
| `package/skills/ax-flow.md` | `f16991d832df0cabeeed4f13c3c831ed2e6fbb1345c476eb4e4a3dda76928193` | typed workflow composition |
| `package/skills/ax-agent.md` | `dd0a93b5840d297cb60932f92f30e737280a0eb882a08d3fae014d215afbaaa9` | ordinary agent construction and execution |
| `package/skills/ax-agent-rlm.md` | `044c413d5ec2155517f8019bb9ca40c3630e90aa05e08cc72775fc792784faff` | recursive long-context execution |

The old executable differential remains immutable evidence for its six exact
vectors. It is not presented as the current Ax surface.

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
  --out benchmarks/runs/ax-contract/ax-contract.json
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

## Current Product-Semantic Disposition

Ax 24.0.4's highest-value portable semantics are now represented through Imp's
ordinary product rather than a parallel Ax-shaped API:

- generic optimizable components use `Imp.ProgramParameters.components/1`,
  validated atomic application, and parameter Artifacts;
- executed ReActV2 programs can be scored from ordered action/result/final
  events, optimized on disjoint rows, restored into trusted tools, and guarded
  by explicit fail-closed per-effect authorization;
- persistent playbook evolution exposes grounded training weaknesses, separate
  promotion and audit gates, explicit review, exact rollback, authoritative
  usage, and verified fresh-runtime checkpoint restore.

Imp deliberately does not copy Ax's flow builder, context maps, binding syntax,
or construction-time automatic production mutation. Ordinary `Imp.Module`
composition and supervised Elixir own control flow; optimizer-visible state is
explicit; evaluation uses replay or sandboxed effects; and installing a
selected immutable program remains an application action. Those are native
design choices, not missing algorithm mechanisms. Future live context or flow
syntax should require a concrete consumer that cannot be served coherently by
the existing module, component, run, and playbook contracts.
