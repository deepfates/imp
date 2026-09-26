# RLM

## Intent

`Imp.rlm(signature, opts)` is for inputs too large, or too uneven, to put in a
prompt. RLM (Recursive Language Model) keeps the inputs out of the prompt as
variables in a small interpreter. The model writes code to look at them, hands
the pieces that need reading to a sub-model, and submits the signature's
outputs from its code. One long-context question becomes a search in code
plus a few short ones.

RLM is experimental: its options, metadata and controller prompt may change
in a minor release.

Read this when a context no longer fits, when the model loses things buried
in the middle of a long one, or when you want the model to decide how to
split a task into pieces.

## Design decisions

### 1. The context lives in variables, not in the prompt

Each input field becomes a variable of the same name. The model sees only a
description of each variable: its type, its length, and a preview, the first
`max_preview_chars` characters of its printed value (2,000 by default). It sees more by
writing code: slicing, splitting, filtering, and printing what it wants to
read. A 900 KB log costs the model the preview until the model decides which
lines matter.

### 2. It takes the same signature as any module

RLM is an inference strategy, not a different kind of task. The inputs you
would give `Imp.predict/2` become variables, and the outputs are what the
model must submit, checked against their types like any prediction. Moving a
program to RLM is a one-line change, and so is moving it back.

### 3. The model drives a loop of code turns

Each turn, the model returns its reasoning and one block of code. Imp runs
the code, and what it printed, or the error it raised, becomes the next
thing the model reads. Variables persist from turn to turn. A turn that
fails rolls back its assignments but keeps the sub-model answers it already
paid for, so the model can fix its code without asking again. The loop ends
when the code calls `submit/1` with valid outputs, and runs for at most
`max_iterations` turns (20 by default).

### 4. Sub-model calls are the recursion

The code can call a model. `llm_query(prompt)` asks the sub-model one
question and returns its answer as a string; `llm_query_batched(prompts)`
asks several at once and returns the answers in order. The usual shape is: find the relevant pieces
with code, have the sub-model read each piece, combine the answers with code.
`rlm_query(prompt)` goes one level deeper and runs the question as a child RLM
with its own interpreter. `max_recursion_depth` (1 by default) is how many
levels of children may start below the top one; at the limit `rlm_query`
becomes a plain `llm_query`.

The sub-model is `sub_lm:`, or the controller's own model when it is not
given. A strong model steering and a cheaper one reading snippets is a good
split: planning the search is harder than reading one line.

### 5. The code is a small language Imp interprets itself

The model writes a subset of Elixir: values, assignment with patterns
(`{a, b} = pair`, `[first | rest] = lines`), `if`, `for` comprehensions with
`into:` and `uniq:`, pipelines, anonymous functions, and the data functions
of `Enum`, `Map`, `List`, `Keyword`, `String` and `Kernel`, except the few
that make atoms or random choices. The controller's prompt lists exactly what
is allowed, and it is the same list the interpreter enforces.

Imp parses the code and walks the syntax tree itself; nothing is passed to
`Code.eval_string/3`, and module calls are limited to an allowlist. This is a
language boundary, not an operating system sandbox: it runs in your VM with
your process's authority, a running cell has no time limit of its own, and the
tools you register are ordinary Elixir functions. Don't run it on untrusted
input where that matters. Keep tools narrow and give them a `tool_policy:`.

### 6. Every budget is separate, and each says how it ran out

Turns, sub-model calls, interpreter steps, value sizes, effects, recursion
depth and wall time are bounded independently, because each protects against
a different runaway: a model that never submits, a loop that fans out into
hundreds of paid calls, code that computes forever, a value that fills
memory. A budget spent inside the code (sub-model calls, steps) is an error
the model reads and can work around; a budget spent on the loop itself
(turns, time) ends the loop.

### 7. Running out of turns is not the end

When the model reaches `max_iterations` without submitting, an extract pass
reads the variables and the whole history once more and fills the outputs
directly. Usually that gives the best answer the exploration supports, marked
`:extract` in the trace; when the extract pass fails too, the call returns an
error.

## API walkthrough

### The loop, with a scripted model

A scripted controller shows the mechanics without a provider. Each step is
what a model would return: reasoning and code.

```elixir
script = fn steps ->
  {:ok, agent} = Agent.start_link(fn -> steps end)

  Imp.LM.Static.new(
    handler: fn _messages, _opts ->
      Agent.get_and_update(agent, fn
        [step | rest] -> {step, rest}
        [] -> {%{reasoning: "", code: "print(1)"}, []}
      end)
    end
  )
end

inbox = """
#1: We were charged twice this month.
#2: I can't log in after resetting my password.
#3: Please add a dark mode.
#4: The API returns 502 errors.\
"""

sub_lm =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      ticket = List.last(messages).content

      cond do
        ticket =~ "charged" -> "atlas"
        ticket =~ "log in" -> "beacon"
        ticket =~ "dark mode" -> "quill"
        true -> "harbor"
      end
    end
  )

controller =
  script.([
    %{reasoning: "See how many tickets there are.", code: ~S|tickets = String.split(inbox, "\n")
print(Enum.count(tickets))|},
    %{reasoning: "Have the sub-model read each ticket.", code: ~S|squads = llm_query_batched(for t <- tickets, do: "Which squad owns this ticket? " <> t)
print(squads)|},
    %{reasoning: "Count and submit.", code: ~S|submit(%{atlas: Enum.count(for s <- squads, s == "atlas", do: s), beacon: Enum.count(for s <- squads, s == "beacon", do: s)})|}
  ])

counter = Imp.rlm("inbox -> atlas: integer, beacon: integer", lm: controller, sub_lm: sub_lm)
{:ok, prediction} = Imp.call(counter, %{inbox: inbox})

{Imp.get(prediction, :atlas), Imp.get(prediction, :beacon)}
#=> {1, 1}
```

The trajectory is in the metadata, one entry per turn:

```elixir
Enum.map(prediction.metadata.trajectory, & &1.code) |> hd()
#=> "tickets = String.split(inbox, \"\\n\")\nprint(Enum.count(tickets))"

Enum.map(prediction.metadata.trajectory, & &1.output) |> Enum.take(2)
#=> ["4", ~s(["atlas", "beacon", "quill", "harbor"])]

prediction.metadata.rlm.sub_lm_calls
#=> 4
```

`prediction.metadata` holds:

- `trajectory`: each turn's `reasoning`, `code` and `output`.
- `rlm_trace`: the same turns with their `action` (`:run`, `:run_error`,
  `:submit`, `:submit_error`, `:action_error`, `:extract`) and depth.
- `final_reasoning`: the reasoning of the turn that submitted.
- `rlm`: counts: `iterations`, `sub_lm_calls`, `elapsed_ms`, the budget, and
  how deep recursion went.

### What the model sees

Every request starts with a system message: what the environment is, the
reply format (one JSON object with `reasoning` and `code`), the built-in
functions, and the language's rules and allowlist. Next come the task:
the signature, your instructions, the required outputs and your tools. Each
turn then adds one message with every variable's description and preview, and
the turns, sub-model calls and time that are left. Earlier turns stay in the conversation as the
model's code and what it printed.

### A log too long to read

The support team's application log has 20,000 lines, about 900 KB. Five of
them are customer messages; the rest are requests, each with its time in
milliseconds.

```elixir
messages = %{
  3_100 => ~s(customer=acme msg="We were billed two times for September."),
  7_450 => ~s(customer=globex msg="Our card shows the same charge twice this month."),
  9_020 => ~s(customer=umbrella msg="Our card was declined twice at checkout."),
  12_880 => ~s(customer=initech msg="Duplicate charge on invoice 2291, please refund one."),
  16_300 => ~s(customer=hooli msg="Charged once, but the receipt email arrived twice.")
}

log =
  Enum.map_join(1..20_000, "\n", fn i ->
    case messages do
      %{^i => message} -> "#{i} SUPPORT #{message}"
      _ -> "#{i} INFO path=/v1/items/#{rem(i * 7, 997)} status=200 ms=#{rem(i * 13, 90) + 10}"
    end
  end)

byte_size(log)
#=> 926857
```

Two questions about it need different tools. How many requests took 95 ms or
more is counting, which code does exactly: 1,110. Which customers were
charged twice is reading: three were, and two others use the same words
about something else, so keywords cannot tell them apart and a model reading
the five messages can.

```elixir
key = System.fetch_env!("OPENAI_API_KEY")

finder =
  Imp.rlm(
    Imp.signature(
      "log -> customers: array[string], slow_requests: integer",
      "The log mixes request lines with support messages. List the customers who were charged twice for the same thing, " <>
        "and count the request lines whose ms is 95 or more. " <>
        "Customers phrase this many ways, so find the support messages with code and have a sub-model judge each one."
    ),
    lm: Imp.req_llm("openai:gpt-5.4", api_key: key),
    sub_lm: Imp.req_llm("openai:gpt-5.4-mini", api_key: key),
    max_iterations: 8,
    max_llm_calls: 20,
    max_interpreter_steps: 2_000_000
  )

{:ok, prediction} = Imp.call(finder, %{log: log})
{Imp.get(prediction, :customers), Imp.get(prediction, :slow_requests)}
#=> {["acme", "globex", "initech"], 1110}
```

In one run, the model's first turn counted the slow requests, kept the lines
that are not requests, and printed them with the count:

```text
lines = String.split(log, "\n", trim: true)
slow_requests = Enum.count(lines, fn line ->
  String.contains?(line, " INFO ") and String.contains?(line, " ms=") and (
    (String.split(line, "ms=") |> List.last() |> String.to_integer()) >= 95
  )
end)
support_lines = for line <- lines, not String.contains?(line, " INFO "), do: line
sample = Enum.take(support_lines, 20)
print(%{total_lines: length(lines), support_count: length(support_lines), slow_requests: slow_requests, sample: sample})
```

Its second turn sent the five messages to the sub-model in one question,
read its answers with code, and submitted:

```text
prompt = "For each support log line below, decide whether the customer is reporting being charged twice / duplicate billed for the same thing. Return exactly one TSV line per input in the same order: YES or NO, then a tab, then the customer name if YES else blank. No extra text.\n\n" <> Enum.join(support_lines, "\n")
resp = llm_query(prompt)
rows = String.split(resp, "\n", trim: true)
...
```

The log never entered a prompt. Each turn's message, with every variable's
description and preview, was 2.3 KB on the first turn and at most 7.8 KB
after; the largest whole request was 17 KB. The runs vary. With `gpt-5.4`
steering and `gpt-5.4-mini` reading, four runs each took two turns and cost
three to five cents; all four counted 1,110, and three of the four returned
exactly those three customers. The fourth submitted an empty list.

Walking 20,000 lines takes more than the default 10,000 interpreter steps per
turn, so this program raises `max_interpreter_steps`. The model reads a step
limit as an error and can try a cheaper approach, but a limit sized to the
data saves turns.

### Budgets and what running out looks like

| Option | Default | Bounds | When it runs out |
| --- | --- | --- | --- |
| `max_iterations` | 20 | controller turns | the extract pass fills the outputs; if it cannot, `{:error, {:rlm_extract_failed, reason, trace}}` |
| `max_llm_calls` | 50 | sub-model calls in the whole call, children included | the code gets `{:error, {:rlm_max_llm_calls, n}}`; with `0`, a sub-model call ends the whole call with `{:error, {:rlm_max_llm_calls, 0, trace}}` |
| `max_time_ms` | none | wall time of the whole call | `{:error, {:rlm_max_time_ms, ms, trace}}` |
| `max_interpreter_steps` | 10,000 | evaluation steps per turn | the code gets `{:error, :step_limit_exceeded}` |
| `max_interpreter_value_bytes` | 16 MB | the size of any one value | the code gets an error |
| `max_interpreter_effects` | 100 | tool and sub-model calls per turn | the code gets an error |
| `max_recursion_depth` | 1 | levels of child RLMs below the top one | `rlm_query` becomes `llm_query`; `recurse/2` fails |
| `max_observation_chars` | 10,000 | how much printed output the model reads back | the output is cut |

Controller turns and the extract pass do not count against `max_llm_calls`;
it bounds the calls the model's code makes. A batch is checked as a whole: a
batch that would pass the limit is refused before any of it is sent.

```elixir
controller =
  script.([
    %{reasoning: "Read every ticket.", code: ~S|squads = llm_query_batched(for t <- String.split(inbox, "\n"), do: "Which squad owns this ticket? " <> t)|},
    %{reasoning: "Out of calls; submit what is known.", code: ~S|submit(%{atlas: 0, beacon: 0})|}
  ])

{:ok, prediction} =
  Imp.call(Imp.rlm("inbox -> atlas: integer, beacon: integer", lm: controller, sub_lm: sub_lm, max_llm_calls: 3), %{inbox: inbox})

prediction.metadata.rlm_trace |> hd() |> Map.take([:action, :output])
#=> %{action: :run_error, output: {:error, {:rlm_max_llm_calls, 3}}}
```

A turn that tries something outside the language fails the same way, and
the model reads why:

```elixir
controller =
  script.([
    %{reasoning: "Read a file.", code: ~S|notes = File.read!("/etc/hosts")|},
    %{reasoning: "Not allowed; answer from the inbox.", code: ~S|submit(%{atlas: 1, beacon: 1})|}
  ])

{:ok, prediction} = Imp.call(Imp.rlm("inbox -> atlas: integer, beacon: integer", lm: controller), %{inbox: inbox})

Enum.map(prediction.metadata.rlm_trace, & &1.action)
#=> [:run_error, :submit]
```

A controller that never submits reaches the extract pass:

```elixir
wanderer =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      if Enum.map_join(messages, "\n", & &1.content) =~ "RLM extract pass",
        do: %{atlas: 1, beacon: 1},
        else: %{reasoning: "Keep looking.", code: "print(1)"}
    end
  )

{:ok, prediction} =
  Imp.call(Imp.rlm("inbox -> atlas: integer, beacon: integer", lm: wanderer, max_iterations: 2), %{inbox: inbox})

Enum.map(prediction.metadata.rlm_trace, & &1.action)
#=> [:run, :run, :extract]
```

### Inputs that are expensive to build

`Imp.rlm_serializable(name, loader, metadata: map)` passes an input as a
handle. The model sees its name and metadata, and the loader runs only if the
code calls `load("name")`. Use it for a value that is costly to read or
fetch, and that the model may not need.

```elixir
lazy = Imp.rlm_serializable(:archive, fn -> String.duplicate("old ticket\n", 1_000) end, metadata: %{tickets: 1_000})

controller =
  script.([
    %{reasoning: "Load the archive only now.", code: ~S|archive = load("archive")
print(Enum.count(String.split(archive, "\n")))|},
    %{reasoning: "Submit.", code: ~S|submit(%{lines: 1001})|}
  ])

{:ok, prediction} = Imp.call(Imp.rlm("archive -> lines: integer", lm: controller), %{archive: lazy})
Imp.get(prediction, :lines)
#=> 1001
```

### Tools, sessions and history

- `tools:` takes `Imp.Tool` values, which the code calls by name like
  functions; `tool_policy:` limits them as in [ReAct](react.md), and a
  refused or crashing tool is an error the code reads. The names of the
  built-ins are reserved.
- `persistent: true` keeps the variables between calls to the same program,
  so a second question can build on the first one's work. Release the session
  with `Imp.Predict.RLM.close/1`.
- `compaction: true` summarizes old turns once the conversation reaches
  `compaction_threshold_pct` of `compaction_context_tokens`, and keeps the full
  history in a `history` variable the code can still read.

### Compared with DSPy's `dspy.RLM`

The idea is the same: inputs as variables with previews, a loop of code
turns, `llm_query` and `llm_query_batched` for sub-model calls, one budget
for those calls across the run, a separate `sub_lm`, and an extract pass when
turns run out.

What differs:

- DSPy's `SandboxSerializable` loads an input into the sandbox eagerly, once
  at the start of each call, and rebuilds rich values there (a DataFrame stays
  a DataFrame). `Imp.rlm_serializable/3` is a lazy handle: the model sees its
  name and metadata, and the loader runs only if the code calls `load/1`.

- DSPy runs Python in a Deno and Pyodide WebAssembly sandbox, and can swap in
  another interpreter. Imp interprets a subset of Elixir itself, against an
  allowlist, in the VM. There is no separate runtime to install or
  configure.
- Imp adds `rlm_query` and `recurse/2` for child RLMs, bounded by
  `max_recursion_depth`, and budgets DSPy does not have: wall time,
  interpreter steps, value size and effects per turn.
- A failed turn rolls back its assignments and keeps the sub-model answers
  it already received.
- The options are `max_iterations` (DSPy's `max_iters`) and
  `max_observation_chars` (DSPy's `max_output_chars`).
- Trajectory and final reasoning are in `prediction.metadata`, not among the
  output fields.
- `persistent: true` and `compaction: true` have no DSPy counterpart.
- DSPy's RLM exposes its predictors to optimizers. Imp's does not yet: an
  optimizer sees no parameters in an RLM program.

## Cross-links

- [Livebook 04](../../livebooks/04_tools_agents_mcp_rlm.livemd): the runnable
  walkthrough, with a scripted loop, lazy loading, batched sub-queries, a
  budget failure and a live run.
- [Modules and composition](modules-and-composition.md): where RLM sits
  among the other strategies.
- [Tools and MCP](tools-and-mcp.md): tools and policies, which RLM shares
  with ReAct.
- [ReAct](react.md): the tool loop, for tasks that act rather than read.
- `Imp.Predict.RLM`: every option.
