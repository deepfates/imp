# DSEx

Program your LMs on the BEAM.

DSEx turns an LM task into an ordinary Elixir value: a typed input/output
signature, a callable program, examples, a metric, and optional program
transformations. The model provider is a runtime dependency, so deterministic
tests use `DSEx.LM.Static` and a live provider does not change the task shape.

Install from Git with `{:dsex, github: "deepfates/dsex", branch: "main"}`.
In a source checkout, use `{:dsex, path: "."}` while developing against the
local repository. Then follow the [Learning Path](docs/LEARNING_PATH.md). It is
the canonical, self-contained route from a signature and `Predict` through
evaluation, measured optimization, tools/ReAct, retrieval, RLM, persistence,
observability, and OTP deployment.

```elixir
# learning-path-contract: readme_predict
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program =
  "question -> answer: short_span"
  |> DSEx.signature("Answer with the shortest correct span.")
  |> DSEx.predict(lm: lm)

{:ok, prediction} = DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})
DSEx.get(prediction, :answer)
```

For source development, clone the repository, run `mix deps.get`, and use
`mix test`. In a source checkout, `mix production.check` is the quality gate and
`mix livebook.execute.check` executes the full notebook learning path.

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

DSEx is inspired by DSPy's goal of declarative, measurable LM programs, with
Elixir-native structs, behaviours, process-local configuration, supervision,
and telemetry.
