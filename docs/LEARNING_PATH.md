# Learning Path

DSEx is easiest to learn as a sequence of small powers. Each step should leave
you with something runnable, inspectable, and testable.

The sequence is deliberately the same everywhere in the docs: declare the
signature, call a program, make it deterministic, measure it, optimize it, add
action boundaries, then operate it.

## In 30 Minutes

Goal: understand the shape of a DSEx program.

1. Read the first example in `README.md`.
2. Open `livebooks/01_real_lm_front_door.livemd`.
3. Run the live cells if `OPENAI_API_KEY` and `OPENAI_MODEL` are configured.
4. Open `livebooks/02_programming_not_prompting.livemd` and run the same shape
   with `DSEx.LM.Static`.
5. Inspect `prediction.metadata.trace.messages`.
6. Change the signature from `question -> answer` to a typed output such as
   `question -> answer: short_span`.
7. If you are starting a real app, follow "Your First DSEx App" in `README.md`
   and put the deterministic program under ExUnit before adding live providers.

You should leave this step knowing that the prompt is generated from a
signature, demos, inputs, and an adapter. The prompt matters, but it is not the
API. You should also know that the same DSEx program can move between a real
provider and `DSEx.LM.Static` without rewriting the task.

When credentials are loaded, each Livebook's proof cells should either return a
validated result or raise. They are demos, but they are also tests.

## In 2 Hours

Goal: turn a prompt-like task into a measurable program.

1. Read `docs/API_GUIDE.md` through "The Canonical Path".
2. Open `livebooks/03_evaluate_and_optimize.livemd`.
3. Build three examples and mark their input fields.
4. Write one metric.
5. Evaluate a baseline.
6. Attach demos with `LabeledFewShot`.
7. Try `RandomSearch` or `InstructionSearch`.

You should leave this step knowing that optimizers improve programs only
through metrics. If the metric is vague, the improvement loop is vague.

## In An Afternoon

Goal: build a useful local workflow.

1. Add schema-constrained outputs with `DSEx.Adapter.JSON`.
2. Add one retrieval or tool boundary.
3. Open `livebooks/04_tools_agents_mcp_rlm.livemd` when the program needs
   controlled action or context exploration.
4. Run the program against deterministic local examples.
5. Save and load the program.
6. From the source checkout, run `mix production.check`.

At this point DSEx should feel like ordinary Elixir: structs, functions,
tests, docs, and explicit dependencies.

## In A Production App

Goal: move from local deterministic behavior to live provider behavior without
rewriting the task.

1. Use `DSEx.req_llm/2` as the provider boundary.
2. Keep model names and API keys in runtime configuration.
3. Use `DSEx.context/2` for request-scoped settings.
4. Keep provider calls out of normal unit tests.
5. From the source checkout, add opt-in live tests with `LIVE_PROVIDER=1 mix live.check`.
6. Watch telemetry, traces, retries, and validation failures.
7. Decide rollout, cost limits, provider-failure behavior, and data-retention
   policy in the host application.

The production move should change the LM dependency, not the shape of the
program. That is the main design promise.

## When To Reach For Advanced Pieces

Use advanced modules when the simpler flow has a real limitation:

- `ChainOfThought` when you need a reasoning field for auditing or scoring.
- `ReAct` when the model must choose tools before submitting an answer.
- `ProgramOfThought` when a small sandboxed Elixir expression is the cleanest
  way to compute the answer.
- `CodeAct` when the model needs a bounded loop of observations and safe code.
- `RLM` when a controller needs to explore context through explicit actions
  instead of stuffing everything into one prompt.
- `DSEx.Agent` when you want an explicit Elixir runtime with tools, child
  agents, traces, and event streams.

Start with the front-door program. Add power only when the task earns it.
