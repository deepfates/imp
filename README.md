# Imp

Program your LMs on the BEAM.

Imp turns an LM task into an ordinary Elixir value: a typed input/output
signature, a callable program, examples, a metric, and optional program
transformations. The model provider is a runtime dependency, so deterministic
tests use `Imp.LM.Static` and a live provider does not change the task shape.

Install the v0.1.0 release from GitHub with
`{:imp, github: "deepfates/imp", tag: "v0.1.0"}` in your `mix.exs` deps.
Imp is not on Hex yet; a Hex release is planned. In a
source checkout, use `{:imp, path: "."}` while developing against the local
repository. Then follow
the [Learning Path](docs/LEARNING_PATH.md). It is
the canonical, self-contained route from a signature and `Predict` through
evaluation, measured optimization, tools/ReAct, retrieval, RLM, persistence,
observability, and OTP deployment.

```elixir
# learning-path-contract: readme_predict
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program =
  "question -> answer: short_span"
  |> Imp.signature("Answer with the shortest correct span.")
  |> Imp.predict(lm: lm)

{:ok, prediction} = Imp.call(program, %{question: "What city is the Eiffel Tower in?"})
Imp.get(prediction, :answer)
```

For source development, clone the repository, run `mix deps.get`, and use
`mix test`. The default `mix test` run is green in a fresh clone with no extra
setup. In a source checkout, `mix production.check` is the quality gate and
`mix livebook.execute.check` executes the full notebook learning path.

## Maintainer checks

The benchmark-evidence and reproduction-registry tests are excluded from the
default `mix test` run (tag `:evidence_infrastructure`). They validate the
committed benchmark artifacts against full git history, the pinned DSPy Python
environments (`scripts/setup_dspy_parity_env.sh` and friends), and in some
lanes a `.env` with provider credentials — none of which a fresh clone has.
To run them:

```sh
scripts/setup_dspy_parity_env.sh
scripts/setup_dspy_current_target.sh
scripts/setup_reference_test_env.sh
EVIDENCE_INFRASTRUCTURE=1 mix test        # or: mix test --include evidence_infrastructure
```

They also need a full (non-shallow) clone, because the source-binding
validators resolve ancestor commit SHAs.

The learning-path snippets are executed by
`test/learning_path_contract_test.exs`; the one live-provider snippet is
explicitly credential-gated. The supplied
`examples/deployment` application shows supervised
artifact loading and bounded concurrent calls.

## Documentation

- [Learning Path](docs/LEARNING_PATH.md)
- [API Guide](docs/API_GUIDE.md)
- [Production Operations](docs/PRODUCTION_OPERATIONS.md)
- [Glossary](docs/GLOSSARY.md)
- [Architecture](docs/ARCHITECTURE.md)

Imp is inspired by DSPy's goal of declarative, measurable LM programs, with
Elixir-native structs, behaviours, process-local configuration, supervision,
and telemetry.
