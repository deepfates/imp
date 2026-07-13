# Adversarial Semantic Saturation Audit

## Finding

The corpus is broad but not semantically saturated. It covers the product's
declared-program core, empirical evaluation, BEAM operation, revision,
provenance, technical failure and recovery, refusal, and visible coordination
with real depth. It does not yet give comparable affirmative treatment to data
power and privacy, accessibility and disability, ownership and market
relations, legal standing and redress, class and coercive power, embodied and
emotional experience, or indirect non-users. Several other regions are large
only in a narrow subframe: print rather than media, wayfinding rather than
place, houses and rooms rather than domestic or hospitality relations, and
sacred borrowings rather than religious/secular plurality.

This is a saturation audit, not a naming decision. It makes no ranking,
shortlist, deletion, rejection, selection, trademark conclusion, or
availability claim.

## Method and observed corpus

Snapshot: filesystem state observed through `2026-07-13T19:00:24Z`. Two
portfolios appeared during the audit (`run-15` and `run-16`) and are included.

Read in full:

- `identity/README.md`
- `identity/atlas.json` (`schema_version: 1`, `atlas_version: 1`, status
  `divergence`)
- `identity/schema/portfolio.schema.json` (used only to check completeness)
- `README.md`
- `docs/DSEX_PHILOSOPHY.md`
- `docs/RESEARCH_LANDSCAPE.md`

Complete inbox files and run IDs observed:

| File | Run ID | Method |
| --- | --- | --- |
| `identity/inbox/01-formal-systems.json` | `run-01-formal-systems` | formal systems repertory grid |
| `identity/inbox/01b-formal-systems-independent.json` | `run-01b-formal-systems-independent` | formal systems repertory grid |
| `identity/inbox/02-empirical-practice.json` | `run-02-empirical-practice` | empirical instrument and publication safari |
| `identity/inbox/03-adaptive-dynamics.json` | `run-03-adaptive-dynamics` | feedback and adaptation morphological matrix |
| `identity/inbox/04-beam-runtime.json` | `run-04-beam-runtime` | BEAM runtime code-first exploration |
| `identity/inbox/05-performance-making.json` | `run-05-performance-making` | performance and making concept blend |
| `identity/inbox/06-built-navigation.json` | `run-06-built-navigation` | built world and navigation analogy sweep |
| `identity/inbox/07-ecology-purpose-transformation.json` | `run-07-ecology-purpose-transformation` | ecology purpose and transformation dialectic |
| `identity/inbox/08-civic-play-learning.json` | `run-08-civic-play-learning` | civic play and pedagogy role-play |
| `identity/inbox/09-boundaries-limits-care.json` | `run-09-boundaries-limits-care` | negative-space boundary and care inquiry |
| `identity/inbox/10-time-plurality-abstract.json` | `run-10-time-plurality-abstract` | time plurality and sound-symbolic construction |
| `identity/inbox/11-cross-cultural-semiotics.json` | `run-11-cross-cultural-semiotics` | cross-cultural semiotic translation relay |
| `identity/inbox/12-code-namespace-protocol.json` | `run-12-code-namespace-protocol` | code namespace protocol forge |
| `identity/inbox/13-plain-language-newcomer.json` | `run-13-plain-language-newcomer` | plain language newcomer conversation |
| `identity/inbox/14-research-epistemic.json` | `run-14-research-epistemic` | epistemic research adversary |
| `identity/inbox/15-performance-brand-architecture.json` | `run-15-performance-brand-architecture` | performance brand architecture stress test |
| `identity/inbox/16-negative-space-futures.json` | `run-16-negative-space-futures` | negative space future scope adversary |

For every candidate, the surface, rationale, etymology, territory and strategy
tags, audience and architecture lenses, and concerns were inspected. `jq` was
used to verify 100 contiguous observations and 20 wildcards per file, compare
all referenced IDs with the current atlas, count actual and intended cells,
and separate words appearing in surfaces/rationales/etymologies from words
appearing only in concerns. Canonical candidate arrays were hashed with
`jq -cS '.candidates' | shasum -a 256` to test lineage independence.

The final snapshot has 1,700 observations, 340 wildcards, 1,527 exact surfaces,
and 1,514 distinct surfaces under a rough lowercase/alphanumeric transform.
The latter is not claimed to be the registry's eventual normalization. All 33
atlas territories have two intended runs in the final snapshot, and every
lexical strategy exceeds its numeric floor. Those are floors, not saturation.

There are important integrity qualifications:

- `run-01` and `run-01b` have identical canonical candidate-array hashes. They
  are two run records but one semantic portfolio, leaving 16 distinct candidate
  arrays across 17 files.
- All 100 `run-08` observations lack candidate-level audience lenses and
  architecture lenses. All 100 `run-11` observations lack architecture lenses.
- An architecture ID tag is not an architecture embodiment. Most rationales do
  not actually show a surface as package, research project, community, hosted
  service, company, protocol, and future artifact system.
- Concern recording is generator-dependent: `run-06` has no `known_concerns`,
  while `run-07`, and runs `11` through `16`, attach concerns to every
  observation. Counts therefore corroborate but do not replace semantic reading.

No native-speaker consultation, cultural-community consultation, user study,
disabled-user research, legal review, security review, or marketplace research
was performed or inferred. In particular, `run-11` is a set of explicitly
uncertain linguistic hypotheses and appropriation flags, not evidence of
cross-cultural acceptance.

## Regions with substantive coverage

1. **Declared, callable programs and honest technical boundaries.** `Declared
   Programs`, `Callable Contracts`, `Effect Boundary`, `Program.Namespace`,
   `Declared Runtime`, `Plain Programs`, and `Empirical Program` explore current
   code and explanation surfaces. Formal terms such as `Fixed Point`,
   `Program Compiler`, `Theorem`, and `Proof-Carrying Prompt` carry explicit
   overclaim analysis. This is affirmative coverage, not only hazards.

2. **Experiment, evidence, uncertainty, and research criticism.** `Trialbook`,
   `Calibration`, `Error Bar`, `Negative Result`, `Construct Validity`,
   `Holdout`, `Objective Function`, `Noise Floor`, and `Unknown Unknowns` span
   trials, metrics, publication, statistical humility, proxy failure, and
   negative lift. This fits the current evaluation APIs and the research
   landscape's insistence on held-out gates, exact authorities, cost, and
   uncertainty.

3. **BEAM operation, provenance, failure, and recovery.** `Restart Ledger`,
   `Checkpoint`, `Fault Domain`, `Pressure Valve`, `Return Path`, `Dead Letter`,
   `Fail Within Bounds`, `Rollback`-adjacent rationales, `Last Known`, and
   `Resumework` make supervision, bounded failure, backpressure, lineage,
   checkpoints, and continuation central. Technical recovery is one of the
   strongest regions and aligns with the P0/P1 artifact and failure campaigns.

4. **Bounded adaptation, refusal, and non-optimization.** `Enough`, `Pause`,
   `Defer`, `Yield`, `Not Yet`, `Quiet Loop`, `Ask Before Acting`, `Let Silence
   Stand`, `Optimize Nothing`, and `Measure, Then Withhold` resist automatic
   growth and autonomy. The corpus recognizes abstention, deferral, rollback,
   and doing nothing as valid outcomes.

5. **Writing, editing, print publication, performance, and making.** `Edition`,
   `Footnote`, `Colophon`, `Manuscript`, `Galleys`, `Score`, `Rehearse`,
   `Stagehand`, `Joinery`, `Programs as Scores`, and `Program Notes for LM
   Systems` provide many affirmative metaphors for versioned artifacts and
   variable executions. Print/editorial and score/rehearsal subregions are
   genuinely covered.

6. **Built systems, routing, and boundary translation.** `Bridge`, `Causeway`,
   `Transit Map`, `Gate`, `Switchyard`, `Translation Layer`, `Schema Port`,
   `Namespace Customs`, and `Artifact Pipeline` cover interfaces, routing,
   operational logistics, and translation loss. The corpus also records
   colonial exploration, military logistics, border, and central-control
   hazards, though mostly as concerns.

7. **Care, visible labor, participation, and affected publics.** `Handoff`,
   `Stagehand`, `The Shift`, `Name the Worker`, `Empty Chair`, `Mark the Missing`,
   `Repair in Public`, `Union`, `Commons`, and `Who Governs the Optimizer?` make
   labor and responsibility visible. `affected-publics` is used in several
   independent runs rather than appended once as an afterthought.

8. **Ecology, purpose, ritual risk, plurality, time, and abstract sound.**
   `Trellis`, `Monoculture`, `Growth Debt`, `Purpose Trace`, `Manytime`,
   `Aftermany`, and the wide phonotactic set in `run-10` and `run-16` extend the
   field beyond literal AI names. Sacred and living-language candidates such as
   `Tikkun`, `Ase`, `Shakti`, `Kavanah`, `Ayniqa`, and `Sankofa` are present as
   culturally loaded probes with explicit uncertainty, not as validated
   cross-cultural coverage.

9. **Portfolio-architecture vocabulary.** Every current architecture ID occurs
   in candidate tags. `run-15` adds master-brand, institute, foundation, studio,
   research-title, community, implementation, and anti-authority forms. It
   usefully exposes that words such as foundation, institute, official,
   standard, commons, union, and sovereign make governance claims.

## Missing or shallow regions

"Concern-only" below means a concept is frequently named as a hazard but has no
coherent affirmative semantic family. A diagnostic keyword scan found privacy/
security language in only 13 surface/rationale/etymology records versus 46
concern records (39 concern-only), and accessibility/disability language in no
substantive affirmative family while 16 concerns mention accessibility. These
figures are diagnostics; the finding rests on the candidate-level reading.

| Region | Coverage diagnosis | Why it matters now and at the artifact horizon |
| --- | --- | --- |
| Trust and legitimacy | **Technical trust is covered; social legitimacy is shallow.** Evidence, explicit limits, provenance, and reproducibility are strong. `Council`, `Foundation`, `Institute`, `Official`, `Protocol`, and `Standard` mostly trigger warnings about borrowed authority. Mandate, representation, standing, contestability, reputation repair, and justified reliance are not a sustained field. | DSEx asks users to rely on runtime boundaries, evaluators, promotion gates, and persisted artifacts. A hosted service, company, protocol, or community steward would also need an account of who may authorize, contest, and revoke decisions. |
| Privacy, security, secrecy, consent, and surveillance | **Shallow and concern-dominant.** `Gate`, `Sandbox Key`, `Ask Before Acting`, and `Wait for Consent` are counterexamples; `Workwatch`, `Panopticon`, `Overseer`, traces, ledgers, and public repair carry surveillance or confidentiality concerns. There is almost no affirmative vocabulary for minimization, confidentiality, selective disclosure, deletion, data custody, authentication, or adversarial defense. | Current calls handle credentials, provider-bound data, redaction, tools, traces, telemetry, and persisted reports. The horizon adds datasets, playbooks, schemas, code, caches, and long-lived lineage, making retention and access power central rather than peripheral procurement concerns. |
| Commerce, ownership, market, and exchange | **Architecture-present, semantics shallow.** Company/product and OSS/commercial tags are present, as are `Shadow Price`, `Sell the Boundary`, `Own the Score`, cost warnings, and many trademark concerns. Missing are who owns optimized artifacts and examples, licensing and derivative work, creator rights, pricing power, lock-in, rent, public goods, procurement incentives, and how value is divided. | A general artifact substrate can create, transform, store, and sell instructions, demonstrations, tool schemas, playbooks, and code fragments. Ownership and market structure affect contributors, customers, upstream creators, and affected people even if DSEx remains a library. |
| Accessibility and disability | **Materially missing.** `Handrail` and `Subtitle` are metaphors, while screen-reader and assistive-technology language appears mainly as a reason symbolic names fail. `Blind Review` is a publishing term, not disability coverage. There is no audience for disabled users or accessibility practitioners and no treatment of cognitive, motor, visual, auditory, speech, or neurodivergent access. | The identity must work in speech, terminals, docs, package tools, conference use, and assistive technology. DSEx also enables applications whose structured outputs and tool actions can include or exclude disabled people. Accessibility cannot be reduced to pronounceability. |
| Bodily, sensory, and emotional language | **Lexically present but narrow.** The corpus uses listening, speaking, hands, warmth, gentleness, care, pressure, and rhythm. It is dominated by visual inspection, spatial movement, and soft warmth. Pain, fatigue, fear, anger, grief, shame, relief, frustration, delight, touch, taste, smell, proprioception, and bodily autonomy have little or no coherent treatment. | Developer trust and affected-person response are emotional and embodied, while "help," "care," "control," and "safety" can feel very different under unequal power. Artifact optimization can amplify tone and interaction patterns beyond code semantics. |
| Domestic life, hospitality, food, and sustenance | **Many objects, little relational depth.** House, room, table, garden, workshop, home, and bench recur; `Lambda Lemonade`, `Arrow Soup`, `Syntax Picnic`, and `No Free Lunch` are mostly playful. Hosting/guest obligations, welcome and refusal, domestic labor, kitchens, meals, provisioning, dependency, and unequal household authority are scarcely explored. | "Hosted" versus local operation is a product distinction, and future services will receive data and artifacts from guests/customers. Hospitality and sustenance offer alternatives to factory, laboratory, battlefield, and growth metaphors, but also expose invisible care work and ownership of the space. |
| Geography, weather, and celestial frames | **Wayfinding is strong; place is shallow.** Maps, routes, ports, north, meridians, and crossings are abundant. `Weather Glass`, `Rain Gauge`, `Weather Vane`, `ORBIT`, `Lunara`, and `Noova` are isolated. Terrain, region, climate, season, disaster, extractive geography, local knowledge, environmental cost, and nonhuman stakes are missing. | Model and provider behavior changes like conditions rather than deterministic machinery, while infrastructure has material locations and environmental externalities. The horizon may persist and optimize resource-intensive artifacts over long periods. |
| Media and publication | **Print/scholarly publication is covered; media systems are shallow.** Presses, editions, manuscripts, notebooks, proofs, peer review, and footnotes are rich. Journalism, broadcast, cinema, audio, social distribution, moderation, virality, audience capture, misinformation, publicity, reputation, and publisher/creator power are mostly absent. | DSEx optimizes meaning-bearing artifacts that may be published at scale. Evaluation and provenance do not by themselves address how media circulates, who edits it, or who bears reputational and informational harms. |
| Legal and judicial relations | **Legal vocabulary exists mostly as analogy or warning.** Contract, terms, court, judgment, witness, disclosure, customs, liability, and `voidable()` appear, but due process, standing, jurisdiction, appeal, remedy, evidence custody, duty, rights, enforcement, and allocation of liability do not form a region. | Tool policies, promotion gates, records, commercial use, and affected-person claims create decisions that may need notice, review, revocation, and remedy. Contract language without redress can overstate accountability. |
| Labor and class | **Coordination and visible work are strong; class power is shallow.** `Handoff`, `Stagehand`, `Shift`, `Union`, `Taskmaster`, `Hidden Hand`, and `Name the Worker` expose work and management. Wages, unpaid maintenance, data annotation, platform/gig work, displacement, bargaining power, owners versus workers, supply chains, and extraction are mostly concern text or isolated counterforms. | Optimized artifacts depend on maintainers, evaluators, dataset labor, provider workers, and domain reviewers. "Automation" and "digital worker" framing redistribute credit, control, and income, not only tasks. |
| Colonial, imperial, military, and policing power | **Counterexamples exist; systematic power analysis does not.** `No Flag Required`, `Command Post`, `Listening Post`, `Blastwall`, `Namespace Customs`, `Imperial Scoreworks`, and `Empire of Care` expose domination. Colonial navigation and military logistics are repeatedly flagged, but policing, carceral control, borders, occupation, extraction, and non-dominating institutional alternatives are sparse. | Observability, routing, policy enforcement, tools, and evaluation can become monitoring and control infrastructure. A vocabulary that notices conquest only in concerns can still normalize its underlying map, logistics, and command frames. |
| Religion, sacred, and secular frames | **Broad borrowing, narrow social frame.** Ritual/magic is an atlas territory and many religious or sacred terms occur, usually with appropriation warnings. Secularism, religious plurality, faith institutions, taboo, blasphemy, conscience, vocation, ordinary ritual, separation of sacred and commercial authority, and users who reject sacred framing are not explored. | Language about invocation, truth, transformation, wisdom, and purpose can claim sacred authority or cause offense. International reach and institutional adoption require more than a collection of decontextualized sacred words. |
| Failure and recovery | **Technical coverage is deep; social recovery is shallow.** Crashes, retries, checkpoints, negative results, rollback, drift, and resume are strong. `Nachsorge`, `Catalogue of Small Failures`, public repair, and warnings that harm may be irreversible are rare. | The roadmap explicitly requires rollback and operational failure campaigns. A technically restored process does not provide apology, remedy, compensation, deletion, reputation repair, or care for people harmed before the restart. |
| Affected non-users | **Present as one broad audience, not saturated.** `Empty Chair`, `Mark the Missing`, `Wait for Consent`, and `affected-publics` are meaningful starts. The atlas collapses data subjects, bystanders, people denied service, people represented in examples, upstream creators, workers, communities, future maintainers, and environmental interests into one class. | Many people affected by an LM program never install the package, see the brand, or meaningfully consent. Artifact reuse and optimization can propagate their data or representations across systems and time. |

### Product-horizon tensions

- **Current library versus general artifact substrate.** Programs, signatures,
  calls, prompts, text, runtime, and modules dominate. Runs `12` through `16`
  mention tool descriptions, retrieval policies, playbooks, schemas, code
  fragments, and configuration in rationales, but these artifact classes do not
  yet have independent semantic depth.
- **BEAM-native identity versus runtime-neutral master.** Both architecture tags
  are common, but few observations actually show how the Elixir package remains
  legible under a broader master without turning the current product into a
  subordinate implementation prematurely.
- **Research project versus dependable product.** Epistemic humility and
  negative results are strong; institute, lab, proof, assurance, and standard
  language often borrows legitimacy. The corpus has not resolved how a serious
  pre-release library speaks without either scientific theater or self-negation.
- **Open community versus commercial custody.** `research-stable-split` has 456
  tags, while `oss-commercial-split` has 31. Neither tag answers ownership,
  governance, funding, hosted-data custody, or contributor power.
- **Local callable code versus hosted service/platform.** The docs distinguish a
  library from a hosted product, but the architecture atlas does not directly
  model embedded/local-only, self-hosted, managed-service, and service-with-data-
  custody variants.
- **Measurement versus value choice.** Metric criticism is deep, yet buyers,
  operators, affected people, workers, and regulators are not embodied together
  when an artifact is promoted. Pareto language does not make omitted values
  commensurable.

## Audience and architecture blind spots

The 19 audience IDs are primarily builders, researchers, maintainers, buyers,
and institutional reviewers. `security-legal-procurement` combines roles with
different duties; `buyers-founders` combines purchasing risk with founder
ambition; `international-users` cannot stand in for localizers, language
communities, or native-speaker review; and `affected-publics` is too broad for
power analysis. `run-08`'s 100 missing audience lenses also leave the civic and
labor portfolio unembodied at candidate level.

Audience classes worth adding provisionally for challenge, not claiming as
researched populations:

- `disabled-users-accessibility-practitioners`
- `privacy-security-practitioners` and `data-subjects-bystanders`
- `domain-users-experts` and `product-design-research`
- `workers-annotators-unions`
- `creators-rightsholders-publishers`
- `regulators-civil-society-redress`
- `providers-tool-owners`
- `localizers-language-reviewers`
- `faith-secular-communities`
- `environment-future-generations`

Architecture tags cover the atlas nominally, but 200 observations have no
architecture lens and most others have only labels, not rendered embodiments.
The atlas is also missing explicit models for:

- an embedded dependency whose brand is invisible to application end users;
- local/self-hosted versus managed-service data custody;
- an artifact registry, exchange, or marketplace without assuming a platform;
- a foundation, cooperative, or member-governed entity distinct from a
  community-themed commercial brand;
- private/internal deployment and white-label use;
- maintainer succession, acquisition, or archival stewardship.

These can initially map to `beam-master`, `neutral-master-beam-implementation`,
`oss-commercial-split`, `community-commercial-steward`, `edition-architecture`,
`lifecycle-planes`, and `federated-compatibility`. Add architecture IDs only
where concrete embodiments show materially different naming obligations.

## Existing mappings versus new atlas concepts

The atlas should not grow merely because a word field is under-sampled. The
following split distinguishes challengeable existing mappings from concepts
that encode a missing relation of power, access, or consequence.

| Semantic need | Existing atlas mapping to try first | Provisional genuinely new concept |
| --- | --- | --- |
| Technical trust, evidence, honest claims | `measurement-evidence`, `declaration-contract`, `persistence-provenance`, `uncertainty-probability`; assessment axis `trust` | None for technical credibility alone |
| Legitimacy, rights, judicial process, remedy | `civic-governance`, `declaration-contract`, `limits-refusal-silence`, `care-stewardship-repair` | `legitimacy-rights-redress` |
| Privacy, security, consent, surveillance, custody | `boundary-translation`, `persistence-provenance`, `distributed-runtime`, `limits-refusal-silence`, `civic-governance` | `privacy-security-data-power` |
| Ownership, licensing, pricing, market exchange | `persistence-provenance`, `labor-coordination`, `civic-governance`, `purpose-praxis`, `infrastructure-logistics` | `commerce-ownership-exchange` |
| Accessibility and disability | `care-stewardship-repair`, `boundary-translation`, `pedagogy-apprenticeship`, `limits-refusal-silence`, `language-semantics` | `access-disability-assistance` |
| Body, senses, emotion, bodily autonomy | `care-stewardship-repair`, `music-notation-performance`, `craft-material`, `uncertainty-probability`, `abstract-sound-symbolic` | `body-sense-affect` |
| Domestic life, hospitality, food, sustenance | `care-stewardship-repair`, `labor-coordination`, `ecology-cultivation`, `civic-governance`, `pedagogy-apprenticeship` | `home-hospitality-sustenance` if challenge candidates cohere beyond objects |
| Place, weather, celestial cycles | `navigation-orientation`, `ecology-cultivation`, `time-recovery-inheritance`, `uncertainty-probability`, `abstract-sound-symbolic` | `place-climate-nonhuman` only for locality and externalities, not scenery |
| Media circulation and public sphere | `writing-editing-publishing`, `language-semantics`, `civic-governance`, `measurement-evidence` | `media-mediation-public-sphere` |
| Labor/class, colonial, military, policing power | `labor-coordination`, `civic-governance`, `limits-refusal-silence`, `navigation-orientation`, `infrastructure-logistics` | `power-coercion-extraction` |
| Religion, sacred authority, secular plurality | `ritual-transformation`, `purpose-praxis`, `civic-governance`, `limits-refusal-silence`, `language-semantics` | `sacred-secular-worldviews` |
| Technical failure and recovery | `distributed-runtime`, `time-recovery-inheritance`, `care-stewardship-repair`, `limits-refusal-silence` | None; social remedy maps to `legitimacy-rights-redress` |

Promotion rule: a provisional concept becomes an atlas territory only if two
independent challenge lineages each produce at least four observations that
cannot be mapped to existing territories without losing the concept's central
power, access, or consequence relation. Otherwise retain it as a cross-cutting
challenge lens.

## Concrete 100-candidate challenge-wave brief

Generate exactly 100 observations with contiguous ordinals and exactly 20
wildcards. Preserve every observation. Do not rank, filter, deduplicate,
availability-check, or expose any current favorite or score. Treat provisional
IDs below as challenge labels until the promotion rule is met.

| Count | Territory focus (`existing`; `provisional-new`) | Intended strategy IDs | Intended audience IDs (`existing`; `provisional-new`) |
| ---: | --- | --- | --- |
| 12 | `boundary-translation`, `persistence-provenance`, `limits-refusal-silence`, `distributed-runtime`, `civic-governance`; `privacy-security-data-power` | `ordinary-object`, `ordinary-verb`, `descriptive-category`, `phrase-imperative`, `symbolic-protocol` | `security-legal-procurement`, `sre-platform`, `affected-publics`; `privacy-security-practitioners`, `data-subjects-bystanders` |
| 10 | `civic-governance`, `declaration-contract`, `measurement-evidence`, `care-stewardship-repair`; `legitimacy-rights-redress` | `institutional-community`, `ordinary-object`, `technical-borrowing`, `phrase-imperative` | `security-legal-procurement`, `affected-publics`, `oss-contributors`; `regulators-civil-society-redress` |
| 10 | `persistence-provenance`, `labor-coordination`, `civic-governance`, `purpose-praxis`; `commerce-ownership-exchange` | `ordinary-object`, `descriptive-category`, `institutional-community`, `coined-category-noun` | `buyers-founders`, `oss-contributors`, `future-maintainers`, `affected-publics`; `creators-rightsholders-publishers`, `workers-annotators-unions` |
| 12 | `care-stewardship-repair`, `boundary-translation`, `pedagogy-apprenticeship`, `limits-refusal-silence`, `language-semantics`; `access-disability-assistance` | `ordinary-verb`, `ordinary-object`, `descriptive-category`, `phrase-imperative`, `abstract-sound-brand` | `elixir-newcomers`, `educators-writers`, `international-users`, `affected-publics`; `disabled-users-accessibility-practitioners`, `product-design-research` |
| 10 | `care-stewardship-repair`, `music-notation-performance`, `craft-material`, `uncertainty-probability`, `abstract-sound-symbolic`; `body-sense-affect` | `ordinary-object`, `ordinary-verb`, `abstract-sound-brand`, `coined-category-noun`, `archaic-cross-language` | `affected-publics`, `educators-writers`, `international-users`, `buyers-founders`; `domain-users-experts`, `disabled-users-accessibility-practitioners` |
| 8 | `care-stewardship-repair`, `labor-coordination`, `ecology-cultivation`, `civic-governance`, `pedagogy-apprenticeship`; `home-hospitality-sustenance` | `ordinary-object`, `ordinary-verb`, `phrase-imperative`, `institutional-community` | `oss-contributors`, `elixir-newcomers`, `international-users`, `affected-publics`; `workers-annotators-unions` |
| 8 | `navigation-orientation`, `ecology-cultivation`, `time-recovery-inheritance`, `uncertainty-probability`, `plurality-ecosystem`; `place-climate-nonhuman` | `ordinary-object`, `technical-borrowing`, `abstract-sound-brand`, `archaic-cross-language` | `affected-publics`, `international-users`, `future-maintainers`, `sre-platform`; `environment-future-generations`, `localizers-language-reviewers` |
| 8 | `writing-editing-publishing`, `language-semantics`, `civic-governance`, `measurement-evidence`; `media-mediation-public-sphere` | `ordinary-object`, `institutional-community`, `descriptive-category`, `phrase-imperative`, `technical-borrowing` | `educators-writers`, `affected-publics`, `buyers-founders`, `security-legal-procurement`; `creators-rightsholders-publishers`, `domain-users-experts` |
| 12 | `labor-coordination`, `civic-governance`, `limits-refusal-silence`, `navigation-orientation`, `infrastructure-logistics`; `power-coercion-extraction` | `ordinary-object`, `ordinary-verb`, `phrase-imperative`, `institutional-community`, `descriptive-category` | `affected-publics`, `oss-contributors`, `security-legal-procurement`, `buyers-founders`; `workers-annotators-unions`, `regulators-civil-society-redress`, `data-subjects-bystanders` |
| 10 | `ritual-transformation`, `purpose-praxis`, `civic-governance`, `limits-refusal-silence`, `language-semantics`; `sacred-secular-worldviews` | `ordinary-object`, `descriptive-category`, `institutional-community`, `abstract-sound-brand`, `archaic-cross-language` | `international-users`, `affected-publics`, `educators-writers`, `oss-contributors`; `faith-secular-communities`, `localizers-language-reviewers` |

### Anti-convergence rules

- Primary-strategy quota across the 100: `ordinary-object` 18,
  `ordinary-verb` 9, `descriptive-category` 9, `phrase-imperative` 9,
  `technical-borrowing` 9, `institutional-community` 9,
  `abstract-sound-brand` 8, `coined-category-noun` 7,
  `archaic-cross-language` 6, `symbolic-protocol` 5, `namespace-led` 3,
  `acronym-initialism` 3, `compound-portmanteau` 3, and
  `proper-mythic-historical` 2. Additional strategy tags are allowed.
- Within each row, generate affirmative, ambivalent, and adverse/counterexample
  forms. Across the wave use 50 affirmative, 25 ambivalent, and 25 adverse.
  Neglected themes must not appear only in `known_concerns`.
- Ground 40 observations in the current Elixir library, 40 in the credible
  artifact horizon, and 20 explicitly across both. Horizon observations must
  distribute attention across instructions, demonstrations, tool descriptions,
  retrieval policies, playbooks, schemas, code fragments, and configuration.
- Every observation must include audience and architecture lenses plus two
  short embodiments: one realistic current package/code sentence and one
  credible horizon, community, service, company, or protocol sentence. A tag
  alone does not satisfy embodiment.
- No more than two surfaces may reuse any one of `lab`, `ledger`, `loom`,
  `garden`, `bridge`, `compass`, `commons`, `workshop`, or `house`. No more than
  four surfaces may lead with `program`, `artifact`, or `optimizer`.
- No more than 15 surfaces may lead with negation (`no`, `not`, `anti`,
  `refuse`, `without`). Refusal is a covered territory; this wave must discover
  positive language for neglected regions as well.
- At most ten surfaces may depend on Greek/Latin prestige. At most five may be
  direct living-language, Indigenous, or sacred borrowings. Record uncertainty
  and cultural stakes; do not claim native-speaker correctness or community
  permission. Abstract forms must not imitate a regional sound merely to appear
  exotic.
- Include at least 15 sensory/emotional observations that do not depend on
  seeing, watching, clarity, or "soft/warm/gentle." Include at least ten
  accessibility observations that address access relations, not only spelling.
- For every surveillance, command, conquest, policing, paternal-care, or
  extraction counterform, include an affirmative alternative in the same row
  that redistributes control or makes refusal/redress possible.
- Do not let a name warrant privacy, security, safety, accessibility, consent,
  fairness, ownership, legal compliance, healing, or improvement. Put the claim
  boundary in the rationale and the power failure in concerns.

## Falsifiable saturation tests

The corpus should be called saturated only if all tests below pass on two new,
independent 100-observation challenge waves generated without prior surfaces,
scores, or favorites.

1. **Independent-lineage test.** Canonical candidate arrays must differ; a
   byte-identical array, as in `run-01`/`run-01b`, counts once. Each existing and
   promoted territory must have observations from at least two distinct hashes
   and methods.
2. **Novel-region yield test.** In each wave, fewer than 5% of observations may
   require a new territory or strategy, matching the atlas threshold. Two
   independent auditors must be able to map at least 95 observations without
   erasing the central power/access/consequence relation. Any coherent omitted
   stakeholder with a material product stake fails the test regardless of the
   percentage.
3. **Affirmative-depth test.** Every existing or promoted challenge region must
   have at least 12 observations across the two waves, including at least four
   affirmative, four ambivalent, and four adverse forms. A region with more than
   60% of its occurrences only in concerns fails.
4. **Audience-embodiment test.** Every atlas and provisional audience must have
   at least ten candidate embodiments across at least two lineages. Each
   embodiment must state what the audience trusts, fears, controls, and bears;
   a tag is insufficient. Combined classes such as `affected-publics` do not
   satisfy their constituent classes automatically.
5. **Architecture-embodiment test.** Zero challenge observations may have an
   empty architecture lens. Every observation must be rendered on a current
   package/code surface and at least one plausible portfolio surface. The
   corpus-wide atlas requirement also remains unmet until the 200 blank-lens
   observations are enriched and tag-only records receive concrete embodiments.
6. **Artifact-horizon test.** Each of instructions, demonstrations, tool
   descriptions, retrieval policies, playbooks, schemas, code fragments, and
   configuration must appear in at least six rationales across at least two
   lineages. At least 25 observations must remain truthful for three or more
   artifact classes without becoming a universal-platform claim.
7. **Power and non-user test.** Disabled people, data subjects/bystanders,
   workers/annotators, creators/rightsholders, people denied service,
   regulators/civil society, and environmental/future interests must each have
   at least eight embodiments that identify benefit, burden, authority, and a
   route to refusal or redress.
8. **Negative-space test.** The corpus must contain at least three independent
   affirmative frames each for deletion/forgetting, confidentiality, revocation,
   abstention, rollback, handoff, remedy after harm, and choosing not to optimize.
   Technical restart cannot substitute for social remedy.
9. **Cross-cultural evidence test.** Direct living-language or sacred borrowings
   remain hypotheses until documented review by relevant language/cultural
   participants. The test fails if uncertain borrowings are counted as positive
   international coverage, if ASCII transliteration is treated as neutral, or
   if one reviewer is generalized to a language or community. No such research
   is claimed in this audit.
10. **Convergence test.** No root/metaphor family may exceed 5% of either wave,
    and no primary strategy may exceed 20%. A semantic cluster analysis must
    distinguish domestic/hospitality from generic "house," media from print,
    place from navigation, and religion/secular plurality from sacred-word
    borrowing.
11. **Reproducibility test.** Publish exact file hashes, run briefs, ID-integrity
    results, candidate and wildcard counts, duplicate arrays, mapping decisions,
    and concern-only classifications. A second auditor using those artifacts
    must reproduce every numeric pass/fail result.

### Current status against the tests

Numeric volume, wildcard fraction, strategy floors, and intended existing-
territory run floors pass in the final snapshot. Independent semantic volume
only reaches 16 arrays because one run pair is identical. The architecture test
fails on 200 blank lenses and broader tag-only embodiment. The affirmative-depth
test fails for privacy/security, accessibility/disability, ownership/market,
legal redress, and several power regions. The audience, artifact-horizon,
non-user, cross-cultural-evidence, and two-wave novelty tests have not been
demonstrated. On those falsifiable criteria, the corpus is not saturated.
