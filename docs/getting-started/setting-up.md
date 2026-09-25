# Setting up

Add Imp to a Mix project:

~~~elixir
def deps do
  [
    {:imp, "~> 0.5"}
  ]
end
~~~

or, for a script or a Livebook notebook:

~~~elixir
Mix.install([{:imp, "~> 0.5"}])
~~~

Imp needs Elixir 1.19 and a C++ compiler for one dependency (erlexec).

## Connecting to a model

Imp reaches models through [ReqLLM](https://hex.pm/packages/req_llm). We give
`Imp.req_llm/2` a `"provider:model"` string and a key:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))
```

Any ReqLLM provider string works in its place: `"anthropic:..."`,
`"google:..."`, `"openrouter:..."`, a local server, and more. Every example in
this guide runs unchanged with any of them, except that the agent in
[Tools and agents](tools-and-agents.md) needs a model with native tool calling. We used `gpt-5.4-mini` for the
outputs shown; yours will differ a little, because models do.

`lm` is a plain struct. We'll pass it to each program with `lm:`, which keeps
the dependency visible in the code and makes it easy to swap. When we'd rather
not repeat it, `Imp.configure(lm: lm)` sets a default for every program, and
`Imp.context/2` overrides it for one block of code.

Let's check that the model answers, with the smallest program there is:

```elixir
hello = Imp.predict("question -> answer", lm: lm)

{:ok, prediction} = Imp.call(hello, %{question: "What is the capital of France?"})
Imp.get(prediction, :answer)
#=> "The capital of France is Paris."
```

With a model connected, we can write the router.

---

**Next:** [Your first program →](first-program.md)
