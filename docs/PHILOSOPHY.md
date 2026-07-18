# Imp Philosophy

Imp starts from a simple shift: treat language-model behavior as software, not
as loose prompt text. You do not need to know another language or framework to
use Imp. The system is taught from Elixir first: explicit data, behaviours,
processes, immutable program structs, and tests.

Imp is the project name for declarative self-improving programs in
Elixir.

## The System In One Sentence

Imp turns language-model work into declared, callable, measurable, improvable
Elixir programs.

The practical sequence is stable across the project: signature, program, call,
deterministic development, metric, optimizer, optional action boundaries, then
operations.

## The framework behind the design

The two kinds of intelligence in the README have names in a conceptual
framework called Gorm fluid and Grug tech. Grug tech means simple,
deterministic, reliable, and maintainable systems, in the spirit of the
[Grug Brained Developer](https://grugbrain.dev). Gorm fluid means the
generative, adaptive, and often non-deterministic capabilities of large
language models.

The core idea is deliberate hybridization with containment. Generative AI
should be injected in controlled doses inside solid structures, used as
lubricant or glue between components, or grown in exploratory patterns and
then distilled into reliable code. The framework warns against both pure
rigidity and unchecked fluidity.

Imp is a toolkit for exactly that practice. Signatures and types are the
solid structure. The model is the fluid, injected at declared points. Metrics
and held-out evaluation are how exploratory gains get distilled into
something you can trust. Optimizers are the distillation step itself.

The concepts originated in the grugbrain.dev philosophy, the Gaspode routine
on [cyborgism.wiki](https://cyborgism.wiki/hypha/grug_tech_gorm_fluid), and
writing on [generative.ink](https://generative.ink/artifacts/gpt-4_gorm_fluid/),
and were refined into practical engineering advice in discussions from 2024
to 2026, especially by the [@deepfates](https://x.com/deepfates) community
on X.

## The pieces are ordinary Elixir values

- Signatures are data. `%Imp.Signature{}` declares inputs, outputs,
  instructions, and constraints.
- Programs are structs. `Predict`, `ChainOfThought`, `ReAct`, and `RLM` hold
  configuration, demos, adapters, and models.
- Boundaries are behaviours. Models, adapters, retrieval, and HTTP clients
  are explicit seams, which is why tests can swap in a scripted model
  without patching anything.
- Optimization is metric-driven. Optimizers compile better programs from
  examples and scores, and a held-out score decides whether the compiled
  program is actually better.

The [Glossary](GLOSSARY.md) defines each term in one or two sentences, and
[Imp for DSPy users](IMP_FOR_DSPY_USERS.md) maps them onto their DSPy
counterparts.

## The prompt is generated, not written

A prompt is a string. An Imp program is a value with a contract, runtime
configuration, traces, examples, metrics, and optimization history. The
adapter renders the prompt from the signature at call time, so the prompt is
an implementation detail of the program rather than the program itself.

```elixir
program = Imp.predict("question -> answer", lm: lm)
{:ok, pred} = Imp.call(program, %{question: "Capital of France?"})
Imp.get(pred, :answer)
```

You can inspect what the adapter rendered whenever you want to see the
machinery. You just never have to maintain it by hand.
