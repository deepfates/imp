# Identity-Space Census

This directory is the Step 8 decision checkpoint for replacing the working
`DSEx` identity. It is a research corpus, not a shortlist and not an instruction
to rename the package. Final selection and implementation wait until the owner
adds the unrevealed candidate to the completed corpus.

Start with [`reports/executive-brief.md`](reports/executive-brief.md) for the
decision state and conclusion-first synthesis. The system map, hostile audit,
and machine-readable reports provide the supporting detail.

The complete 2,052-candidate frontier is in
[`reports/candidate-tier-index.tsv`](reports/candidate-tier-index.tsv), with one
candidate per row. Each role cell uses `tier/rank` (`A/3` means tier A, rank 3
for that role); `best_rank` is only a compact sort key, not a universal score.

The current owner-guided naming pass is in
[`reports/taste-convergence-review.md`](reports/taste-convergence-review.md).
It ranks the complete 220-name owner-guided frontier, preserves every generated
candidate, separates master-brand and narrower-role judgments, and holds the
unrevealed candidate outside the field for a blind comparison.

The separate
[`reports/finalist-preliminary-screen.md`](reports/finalist-preliminary-screen.md)
records current namespace and public-market observations for the top 20. It
does not silently convert collision evidence into rank or legal clearance.

The checkpoint follows the repository rule that no generation is silently
discarded. Raw portfolios are immutable inputs. Repeated names, malformed
ideas, collisions, adverse connotations, and candidates that fail a later gate
remain in the corpus with explicit flags.

## Identity Layers

The work separates four related decisions:

1. **Master brand**: the memorable and protectable identity.
2. **Category descriptor**: the plain explanation of what the system is.
3. **Portfolio architecture**: the relationship among the Elixir library,
   research, community, hosted service, company, protocol, and future products.
4. **Code nomenclature**: package, OTP application, module root, Mix tasks,
   configuration, telemetry, artifacts, and command forms.

One word does not have to perform all four jobs.

## Source Of Truth

- `atlas.json` defines the product boundary, semantic territories, audiences,
  lexical strategies, brand architectures, assessment axes, and coverage rules.
- `workflow.json` declares planned generation waves and downstream coverage
  requirements. It is the denominator for progress, not a ranking surface.
- `schema/portfolio.schema.json` is the locked contract for independent
  generation runs.
- `inbox/*.json` preserves each raw generation portfolio exactly as accepted.
- `registry.jsonl` is the derived append-only event corpus. Every raw occurrence
  receives its own occurrence ID, including duplicates.
- `enrichments.jsonl`, `assessments.jsonl`, `flags.jsonl`, and `dissent.jsonl`
  add embodiments, evidence, interpretations, and disagreement without mutating
  candidate observations.
- `scenarios.json` contains provisional, visible decision weights and tier
  thresholds. It defines several views and no universal winner.
- `reports/` contains reproducible views. Reports are projections, never the
  authority for whether a candidate exists.

Accepted inbox files are not edited. Corrections and reinterpretations are new
events that reference the earlier record. Generated reports may be rebuilt.

## Live Progress

Run `mix dsex.identity.progress` for the accepted frontier, valid work awaiting
acceptance, assigned or planned portfolios, wave completion, and downstream
registry, enrichment, assessment, and collision coverage. Use `--json` for
automation or `--out identity/reports/progress.json` for a dated snapshot.

The acceptance boundary is mechanical: a portfolio counts as accepted only
when `workflow.json` declares it, its candidate count exactly matches that
declaration, it is schema-valid, it is tracked by Git, and its contents are
unchanged from `HEAD`. Valid uncommitted work remains visible as pending, while
partial, undeclared, and assigned files remain visible without entering
accepted totals.

## Process

### 1. Ground The Product

Read the implementation, public API, documentation, research horizon, release
ledger, and rename-impact surfaces. Record what exists, what is planned, and
what remains uncertain. Do not allow a candidate to decide the product's
architecture by metaphor.

### 2. Build The Atlas

Map semantic territories, connotational hazards, audience vocabularies, lexical
formation strategies, identity architectures, and cross-cutting axes before
candidate generation. The atlas is extensible: a newly discovered region is
added rather than forced into the nearest existing category.

### 3. Diverge In Isolated Portfolios

Generation runs receive bounded, different briefs. Some begin from a semantic
territory, some from an audience, some from sound or morphology, some from code
surfaces, and some from deliberate category errors or negative space. Runs do
not see favorites or scores from earlier runs.

No availability, trademark, domain, or popularity screen is used to suppress
generation. A generator may note a known concern, but the candidate remains.

### 4. Register Without Loss

Ingestion preserves raw spelling, rationale, etymology, pronunciation,
territories, strategies, method, model, prompt, run order, and lineage. A
normalized key groups equivalent forms for analysis; it never collapses their
occurrences or provenance.

### 5. Enrich

Candidates are embodied and inspected as:

- a spoken recommendation and support-call phrase;
- a Hex package and OTP application atom;
- an Elixir module root, Mix task, config prefix, and telemetry prefix;
- a README headline, paper title, conference sentence, and error message;
- an open-source project, research program, company, platform, and product
  family where those architectures are plausible;
- a word encountered by international and non-native-English users.

Collision, cultural, linguistic, legal, and ecosystem research records sources,
dates, jurisdiction or registry, confidence, and whether the claim is observed
or inferred. A search result is not trademark clearance.

The baseline enrichment includes a deterministic BEAM screen for Unicode,
script mixing, code-projection loss, speech ambiguity, and source-language or
proper-name review signals. It reports `attention` and `unverified` evidence;
it never counts as native-speaker, community, accessibility-user, or legal
validation.

### 6. Evaluate Without Erasure

Assessments are independent records with an assessor, optional audience or
scenario context, axis scores, confidence, evidence, and free-form reasoning.
The three-profile checkpoint corpus is global: its context objects are empty,
and the later scenarios reweight those global vectors rather than impersonating
audience research. Factual defects are flags, not negative scores disguised as
facts. Preference, predicted audience response, and observed evidence remain
separate.

Use `mix dsex.identity.assess --plan` to inspect the exact pending work before
calling providers. The production model lanes are declared explicitly rather
than inherited from mutable defaults:

```text
--profile terra=openai_codex:gpt-5.6-terra
--profile sonnet=openrouter:anthropic/claude-sonnet-5
--profile flash=openrouter:google/gemini-3.5-flash
```

The runner validates every candidate ID, atlas axis, score, confidence, and
evidence reference; writes append-only assessment and failure ledgers through
atomic checkpoints; and resumes only records whose profile, atlas, and exact
candidate-evidence digests still match. These are model assessments, never a
substitute for listener, user, cultural, legal, or accessibility review.

Provider shard files are resumable build intermediates. Once every profile is
complete, consolidate them explicitly:

```text
mix dsex.identity.assessments.consolidate \
  --assessment 'identity/research/assessments.flash*.jsonl' \
  --assessment 'identity/research/assessments.sonnet*.jsonl' \
  --assessment 'identity/research/assessments.terra*.jsonl' \
  --run-ledger 'identity/research/assessment-runs.flash*.jsonl' \
  --run-ledger 'identity/research/assessment-runs.sonnet*.jsonl' \
  --run-ledger 'identity/research/assessment-runs.terra*.jsonl' \
  --profile flash --profile sonnet --profile terra
```

Consolidation rejects incomplete candidate/profile matrices, schema failures,
evidence or profile drift, duplicate records, malformed run sequencing, and
assessment IDs without exactly one successful batch event. It writes the
canonical assessment and run ledgers plus a source-hash audit. Raw shards may
be removed only after that audit passes and `mix dsex.identity.assess --plan`
reports every canonical record resumed with no work planned.

The corpus supports several views:

- per-axis score distributions;
- declared product-context sensitivity views over the global score vectors;
- Pareto frontiers without a universal weighting;
- provisional tiers within a declared scenario;
- wildcard, dissent, and resurrection pools;
- flagged and collision-heavy candidates, still recoverable.

Scenario scores use an equal mean across the completed assessment profiles.
Model-reported confidence remains visible as metadata but does not weight the
vote: confidence scales are not calibrated across providers, and allowing one
provider's confidence style to determine its influence would break jury
independence.

Run `mix dsex.identity.reliability` to publish per-axis and per-scenario
pairwise rank agreement, score bias, error, and two-way ICC(A,1)/ICC(A,k) and
ICC(C,1)/ICC(C,k). These are descriptive diagnostics, not automatic acceptance
thresholds. Run `mix dsex.identity.review` to derive deterministic scenario
score previews, 20-percent-wildcard deliberation pools, the full wildcard and
Pareto pools, model disagreements, flagged contenders, and axis-based
resurrection candidates without deleting or selecting anything.

No global winner is computed during divergence.

### 7. Test Saturation

Completion requires both quantitative coverage and qualitative challenge. The
minimums in `atlas.json` are floors, not proof by themselves. Later waves must
deliberately attack missing cells, non-obvious audiences, cross-cultural blind
spots, and underrepresented lexical mechanisms.

The search is considered saturated only when two independent challenge waves
add little new semantic or morphological coverage, every required region has
multiple independent generation lineages, and an adversarial audit cannot name
an unexamined identity strategy or audience with a material product stake.

### 8. Decision Checkpoint

Publish the full registry, coverage report, candidate cards, scenario tiers,
Pareto views, flags, dissent, saturation audit, hostile audit, and unresolved
human gates. Then add the owner's hidden candidate as a blind portfolio entry
and evaluate it under the same protocol. Final selection and rename execution
are a later decision.

## Anti-Convergence Rules

- Do not delete candidates.
- Do not show generators the current leaders.
- Do not let one scalar score replace the underlying axes.
- Do not treat an LLM's audience prediction as user research.
- Do not mix collision facts with taste.
- Preserve duplicates, minority interpretations, and repaired variants.
- Keep at least 20 percent of every deliberative narrowing pool as wildcards or
  underrepresented-territory representatives; retain raw rank previews as
  unmodified diagnostics.
- Record why a view excludes an entry; views never remove registry records.
- Keep descriptions technically honest: terms such as safe, proof, typed,
  compiler, autonomous, reliable, standard, and platform carry claims.

## Reproducibility

Each run records the generator, model or human source, method, prompt text or
prompt path and hash, timestamp, atlas revision, intended coverage, and parent
run or candidate lineage. Deterministic tooling validates IDs and references,
reconstructs normalized candidate entities, audits input-to-registry counts,
and renders reports from the event corpus.
