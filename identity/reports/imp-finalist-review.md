# Imp Finalist Review

## Conclusion

`Imp` passed the intrinsic identity review and became the selected identity on
2026-07-14 after the owner accepted the documented coexistence tradeoff. It is
more memorable, more natural in Elixir code,
more extensible as a product family, and less derivative of DSPy while retaining
the intended lineage:

> **Imp: Declarative self-improving Elixir**

It does **not** receive an unconditional market or legal-risk pass. Active
exact-name AI projects make this a knowingly shared identity, not a clean
namespace. The decision is therefore straightforward:

- choose `Imp` if the objective is the strongest name for this Elixir package
  and the owner accepts qualified coexistence;
- do not choose `Imp` if broad exclusivity across AI infrastructure, developer
  tools, and future hosted services is a hard requirement.

The owner has authorized the code cutover and explicitly treats the unrelated
same-name software projects as non-blocking. This report preserves the observed
collision evidence without turning it into an implementation gate.

## Why It Works

`Imp` is an ordinary word before it is a reference. It is short, speakable,
spellable, memorable, and coherent across the full code identity:

| Layer | Projection |
| --- | --- |
| Brand | `Imp` |
| Descriptor | `Declarative self-improving Elixir` |
| Module root | `Imp` |
| Hex and OTP application | `imp`, `:imp` |
| Mix tasks | `mix imp.*` |
| Telemetry | `[:imp, ...]` |
| Environment | `IMP_*` |
| Artifacts | `imp_*`, `imp-*` |

The DSPy relationship does not require a backronym. `Imp` is embedded in
*self-improving*, so the original idea remains visible without making the new
project sound like a port or unofficial extension.

The ordinary meaning carries useful personality: a small active presence that
gets into a program and changes it. [Merriam-Webster](https://www.merriam-webster.com/dictionary/imp)
also records an older verb sense: to graft or repair a bird's feather so it can
fly properly, or to equip it with wings. That repair-and-improvement image is
unusually apt, but should remain a secondary story rather than the public
explanation.

## What Could Break It

The main risk is collision, not code ergonomics.

1. [`kekzl/imp`](https://github.com/kekzl/imp) is an active exact-name C++/CUDA
   inference engine for agentic AI. It was created in 2026 and reports a large
   implementation, test, and benchmark surface. This is a same-audience use,
   even though the product layer differs.
2. [`halljoshr/imp`](https://github.com/halljoshr/imp) is a very small 2026
   project describing an AI-powered engineering workflow framework for
   planning, validation, review, and metrics. Its current footprint is tiny,
   but its category is close.
3. [`MILVLG/imp`](https://github.com/MILVLG/imp) is the released code for a
   published Imp multimodal-model family.
4. [Electric Imp](https://www.electricimp.com/platform/how-it-works/) remains an
   active IoT software and hardware platform.
5. `IMP` is conventional terminology for toy imperative languages in
   programming-language research. Python also had a standard-library `imp`
   module, removed in Python 3.12.

The first two are material. The others increase crowding and search cost. None
alone proves legal conflict, but together they mean the project cannot honestly
claim a clean or exclusive software identity.

The primary English senses are "small demon" and "mischievous child." That can
be charming for an open-source developer tool, but it can also imply toy-like,
uncontrolled, or untrustworthy behavior. The implementation's actual rigor and
the permanent descriptor must carry the counterweight; a demonic mascot or
autonomy-heavy positioning would amplify the wrong reading.

## Technical Screen

- Hex returned HTTP 404 for exact `imp`: no public record was observed, not a
  registration guarantee.
- No `imp` or `Elixir.Imp` BEAM artifact appeared in the current build outputs.
- No local `imp` executable or `IMP_*` environment variable was observed.
- `deepfates/imp` returned no GitHub repository, while 16 exact `imp` repository
  names appeared among the first 100 GitHub search results.
- Exact records exist on crates.io and npm; PyPI returned no exact record, but
  a project branded `imp` publishes as `impx` and Python's historical module
  complicates the namespace.

The Elixir projection is clean enough to implement. The broader brand is not.

## Imp Versus DSX

| Concern | Imp | DSX |
| --- | --- | --- |
| Owner taste | Stronger | Strong backup |
| Master-brand recall | Stronger | Acronym-like and generic |
| DSPy lineage | Conceptual and independent | Literal and derivative |
| Elixir code ergonomics | Stronger | Acceptable but acronym-heavy |
| Product-family extension | Stronger | Sounds like one implementation |
| Exact Hex record | None observed | None observed |
| Direct public conflict | Several smaller AI/software uses | NVIDIA DSX in adjacent AI infrastructure |
| Broad ownability | Weak | Weak |

`Imp` wins the comparison, but not by being collision-free. It wins because its
identity fit is materially better while `DSX` has its own larger adjacent AI
collision and weaker intrinsic character.

## Recommendation

The owner answered the explicit decision question in favor of the best-fitting
Elixir identity despite the shared software namespace. Treat `Imp` as the
**selected identity** and execute the hard pre-release rename described in
[`rename-surface-audit.md`](rename-surface-audit.md).

> Are we choosing the best-fitting Elixir identity even though active AI
> projects already use the same short name, or is broad software-brand
> exclusivity a requirement?

The authoritative naming grammar and historical boundary are recorded in
[`../DECISION.md`](../DECISION.md). This review remains the dated risk analysis
and does not claim the implementation rename is complete.

The machine-readable evidence and limitations are in
[`imp-finalist-screen-01.json`](../research/imp-finalist-screen-01.json). The
owner's pre-reveal answers and final identity projection are preserved in
[`owner-heldout-01.json`](../preferences/owner-heldout-01.json).
