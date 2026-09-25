# Saving and artifacts

## Intent

An optimizer's output is data: instructions, demos and model settings. Imp
keeps it in one of two forms. A **portable program** (`Imp.save!/3` and
`Imp.read!/2`) is the whole program as JSON, for programs built from Imp's own
modules. A **parameter artifact** (`Imp.Optimizer.Artifact`) holds only the
tuned parameters, which your application applies to a program its own code
builds. Neither holds credentials.

Read this when you ship an optimized program, keep optimizer output under
version control, or load parameters into a running service.

## Design decisions

### 1. Two forms: the whole program, or its parameters

Save the whole program when it is made of Imp's modules: `Imp.predict/2`,
`Imp.chain_of_thought/2`, RAG, BestOfN, Refine and the others. Save
parameters when the program is your own struct implementing `Imp.Module`, or
when you want the program's code to live in your release and only its tuned
text to cross the persistence boundary. The
[deployment example](https://github.com/deepfates/imp/tree/main/examples/deployment)
does the second.

### 2. JSON with a checksum

Both forms are pretty-printed JSON you can diff and review, written
atomically and readable only by the user that wrote them (mode 0600). Each
file carries a SHA-256 of its contents and a schema version; loading
refuses a file whose checksum does not match or whose version it does not
know, rather than loading part of it.

### 3. Credentials are never saved

An artifact gets committed, attached to pull requests, copied between
machines and read by people who should not hold your provider key. So the
model's settings are saved (provider, model name, temperature) and its key
is not, and there is no option to include it. Keys are dropped by name and
redacted by shape. The machine that runs the program supplies the key when
it loads it.

### 4. Loading runs no code from the file

A saved program that needs a function, such as the metric inside BestOfN or
a tool's runner, stores the function's *name*. Loading looks the name up in
an `Imp.Saving.Registry` that your code builds from functions it trusts, and
refuses a name it does not find. Adapters and model clients come from an
allowlist, and loading never creates atoms from strings in the file. A file
can choose among functions you registered; it cannot bring its own.

### 5. A program that cannot be saved faithfully is not saved

A program pinned to a model Imp cannot describe in JSON, such as the scripted
`Imp.LM.Static`, fails to save instead of saving something that would load
and quietly answer with a different model:

```elixir
scripted = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end)
pinned = Imp.predict("ticket -> team", lm: scripted)
path = Path.join(System.tmp_dir!(), "router.json")

try do
  Imp.save!(pinned, path)
rescue
  error in ArgumentError -> Exception.message(error)
end
#=> "Predict LM is not portable; pin ReqLLM or use dynamic settings, got: Imp.LM.Static"
```

Build the program without `lm:` to save it unpinned; it then uses whatever
model is in the settings where it runs.

### 6. Parameters are applied to code you trust

A parameter artifact holds each predictor's name, signature, demos and
config, and nothing else: no module, model, adapter, callback or tool. Your
application builds the program, then `Imp.Optimizer.Artifact.apply/4` copies
the parameters onto it after checking that the predictors and their
signatures match. A mismatch raises and changes nothing, so a stale artifact
cannot half-install itself.

### 7. An artifact keeps its history

A parameter artifact holds a champion, any number of challengers, and the
champions it replaced. `promote/2` and `rollback/1` move between them and
bump the revision, so what is serving, and what served before it, is in the
file.

## API walkthrough

### Portable programs

Save the ticket router, with a demo and a pinned model:

```elixir
lm =
  Imp.req_llm("openai:gpt-5.4-mini",
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    temperature: 0
  )

router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)
  |> Imp.with_demos([
    Imp.example(ticket: "We were charged twice this month.", team: "atlas")
  ])

:ok = Imp.save!(router, path)

File.read!(path) =~ System.fetch_env!("OPENAI_API_KEY")
#=> false

loaded = Imp.read!(path)
{loaded.lm.model, loaded.lm.opts, length(loaded.demos)}
#=> {"openai:gpt-5.4-mini", [temperature: 0], 1}
```

The file holds the signature, the demo, the adapter and
`"lm": {"provider": "req_llm", "model": "openai:gpt-5.4-mini", "opts":
[["temperature", 0]]}`. Give the loaded program its key by binding a model:

```elixir
serving =
  Imp.with_lm(
    loaded,
    Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))
  )
```

`Imp.with_lm/2` pins every predictor in the program, however deeply nested.
A loaded program that keeps its saved model looks its key up the way ReqLLM
does, from application config or the environment; binding it yourself makes
the source of the key explicit.

`Imp.dump/1` and `Imp.load/1` are the same conversion without the file: a
JSON-safe map in, `{:ok, program}` or `{:error, reason}` out. `Imp.load!/1`
raises instead.

### Functions by name

BestOfN keeps a metric, so saving it needs a registry that names the metric:

```elixir
known_team = fn _example, prediction ->
  Imp.get(prediction, :team) in ~w(atlas harbor beacon quill)
end

best_of_three = Imp.best_of_n(router, known_team, n: 3)
registry = Imp.Saving.Registry.new(known_team: known_team)

:ok = Imp.save!(best_of_three, path, registry: registry)
loaded = Imp.read!(path, registry: registry)

try do
  Imp.read!(path)
rescue
  error in ArgumentError -> Exception.message(error)
end
#=> "saved BestOfN metric references unknown registry callback \"known_team\""
```

### Parameter artifacts

Capture what an optimizer chose, write it, and apply it to a freshly built
program. The scripted model keeps this example offline:

```elixir
build_router = fn lm ->
  Imp.predict("ticket -> team: enum[atlas,harbor,beacon,quill]", lm: lm)
end

trainset =
  for {ticket, team} <- [
        {"We were charged twice this month.", "atlas"},
        {"Webhooks stopped arriving at 3am.", "harbor"}
      ],
      do: Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)

improved =
  Imp.optimize!(
    build_router.(scripted),
    Imp.Optimizer.LabeledFewShot.new(k: 2),
    trainset
  )

artifact =
  Imp.Optimizer.Artifact.from_optimized_program(improved, artifact_id: "router-v1")

artifact_path = Path.join(System.tmp_dir!(), "router-parameters.json")
:ok = Imp.Optimizer.Artifact.write!(artifact, artifact_path)

deployed =
  artifact_path
  |> Imp.Optimizer.Artifact.read!()
  |> Imp.Optimizer.Artifact.apply(build_router.(scripted))

{length(deployed.demos), Imp.Optimizer.Report.fetch(deployed).optimizer}
#=> {2, :labeled_few_shot}
```

Applying to a program whose signature differs is refused:

```elixir
try do
  Imp.Optimizer.Artifact.apply(
    artifact,
    Imp.predict("ticket, customer -> team", lm: scripted)
  )
rescue
  error in ArgumentError -> Exception.message(error)
end
#=> "optimizer artifact predictor \"main\" has an incompatible signature"
```

`Imp.Optimizer.Artifact.inspect/1` summarizes an artifact without loading
anything from it, including what it attests about itself:

```elixir
Imp.Optimizer.Artifact.inspect(artifact).security
#=> %{"credentials_absent" => true, "functions_absent" => true, "json_safe" => true, "redaction_policy" => "imp_default_v1"}
```

GEPA can return the program, its report and the artifact in one step with
`Imp.Optimizer.GEPA.compile_with_artifact/5`. `Imp.Experiment.check/5`
returns the artifact of the program it selected.

### Champion and challengers

```elixir
v2 =
  Imp.optimize!(
    build_router.(scripted),
    Imp.Optimizer.LabeledFewShot.new(k: 1),
    trainset
  )

artifact =
  Imp.Optimizer.Artifact.new(
    Imp.Optimizer.Artifact.parameter_candidate("router-v1", improved, score: 0.80),
    [Imp.Optimizer.Artifact.parameter_candidate("router-v2", v2, score: 0.85)]
  )

Imp.Optimizer.Artifact.compare(artifact, "router-v1", "router-v2").changed_predictors
#=> ["main"]

promoted = Imp.Optimizer.Artifact.promote(artifact, "router-v2")

Imp.Optimizer.Artifact.inspect(promoted)
|> Map.take([:champion_id, :revision, :rollback_depth])
#=> %{champion_id: "router-v2", revision: 2, rollback_depth: 1}

rolled_back = Imp.Optimizer.Artifact.rollback(promoted)
Imp.Optimizer.Artifact.inspect(rolled_back) |> Map.take([:champion_id, :revision])
#=> %{champion_id: "router-v1", revision: 3}

File.rm(path)
File.rm(artifact_path)
```

`apply/4` takes a candidate id as its third argument to apply a challenger
instead of the champion.

## Cross-links

- [Choosing an optimizer](choosing-an-optimizer.md): what each optimizer
  changes, and so what an artifact of it contains.
- [Settings and context](settings-and-context.md): running an unpinned
  loaded program under a model chosen at run time.
- [Running Imp in production](../production.md): loading an artifact at
  startup and reloading it while serving.
- `Imp.Saving` and `Imp.Optimizer.Artifact` document every function.
