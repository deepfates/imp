# Glossary

Imp uses a small vocabulary. These words are meant to describe ordinary
Elixir values, not magic.

The main workflow is: define a signature, build a program, call it, evaluate
predictions with examples and metrics, optimize the program, and operate it
through an explicit LM dependency.

## Adapter

An adapter turns a signature, inputs, and demos into model messages, then turns
raw model output back into a `Imp.Prediction`.

Use `Imp.Adapter.Chat` for readable field-labelled text. Use
`Imp.Adapter.JSON` when output shape matters. Use `Imp.Adapter.SingleField`
for a strict one-output classifier or scalar program whose model should return
only the value; it rejects multi-output signatures and does not repair labelled
or bracketed prose into an answer.

## Artifact

Imp has two explicit artifact forms. `Imp.save!/2` and `Imp.load!/1` persist a
portable built-in program, including its shape, instructions, and demos.
`Imp.Optimizer.Artifact` persists selected parameters for application-owned
program code; reconstruct the trusted module and apply those parameters after
restart. Neither form stores provider credentials. Review and version either
one like the deployable state it is.

## Demo

A demo is an example attached to a program so the model can see the desired
input/output pattern. Demos are data, not hidden prompt strings.

## Dev Set

A dev set is the set of examples used to choose between candidate programs.
Imp's Experiment API calls this the **selection set** to make that role
explicit. Optimizers may score candidates on dev data during search; final
admission and untouched testing remain separate stages.

## Example

An example is a row of named data. `Imp.with_inputs/2` marks which fields are
inputs; the remaining fields are labels.

## LM

An LM is the runtime model dependency. In tests this is often
`Imp.LM.Static`. In production it is usually `Imp.req_llm/2`.

## Metric

A metric scores a prediction against an example. Return a boolean for a strict
pass/fail check, a number for graded credit, or `Imp.Metrics.Result` (or its map
shape) when an optimizer or report also needs feedback and metadata.

## Optimizer

An optimizer compiles a better program from examples, metrics, and candidate
changes. Optimizers may choose demos, rewrite instructions, search program
variants, or optimize text artifacts.

## Prediction

A prediction is the structured output of a program. Read signature-declared
dynamic fields with `Imp.get/2`; ordinary struct fields such as `metadata` and
`completions` can use dot access. Predictions can also carry scores and traces.

## Program

A program is a callable Imp struct such as `Predict`, `ChainOfThought`,
`ReAct`, `ProgramOfThought`, or `CodeAct`. Programs hold or wrap the signature,
adapter, LM, demos, configuration, and metadata needed to run.

## Signature

A signature is the task contract: named inputs, named outputs, field types,
constraints, and instructions.

Example:

```elixir
Imp.signature("question -> answer: short_span")
```

See the [signature type DSL](API_GUIDE.md#signature-type-dsl) for every scalar,
array, enum, and answer-shape spelling and its validation behavior.

## Test Set

A test set (held-out set) is data that nothing selected against: not the
optimizer, not you while iterating. Its score is the only honest answer to
"did this get better?"

## Trace

A trace records what happened around a call: generated messages, raw model
output, retries, tool calls, and related metadata. Traces are for debugging and
evaluation, and Imp redacts common secret-shaped values.

## Train Set

A train set is the set of examples an optimizer can use to build candidates,
for example by selecting demos. It is distinct from the dev/selection set that
chooses a candidate and the test set that estimates the selected result.
