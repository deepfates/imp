# ReAct

## Intent

`Imp.react(signature, tools, opts)` is Imp's tool-using loop. The model reads
the task, calls tools, reads their results, and repeats until it can give the
signature's outputs. It is DSPy's ReActV2: the history is structured, tools
are called natively through the provider, one step may call several tools,
and the answer arrives directly rather than through a separate extraction
call.

This module is experimental: its options and metadata may change in a minor
release.

Read this when a task needs the model to choose actions, when you want to
know why a turn ended the way it did, or when you are moving an agent from
DSPy's `ReAct` or `ReActV2`. For defining tools and importing them from MCP,
see [Tools and MCP](tools-and-mcp.md).

## Design decisions

### 1. The history is structured, and it is the prompt

Every step is recorded as one entry in an `Imp.History`: the inputs (on the
first step), the model's thought if it wrote one, its tool calls with their
IDs, and each call's result. The adapter replays that history as real
messages: an assistant message with native tool calls, then one tool message
per result, matched by ID. Nothing earlier is reformatted, so each request is
the previous one plus the newest exchange, which is the prefix a provider's
prompt cache can reuse.

The history comes back as `prediction.metadata.history`. Pass it as the
`history` input of the next call to continue the conversation.

### 2. How a turn ends depends on the outputs

A signature with **one unconstrained text output** (`ticket -> reply`) ends the way most
tool loops end: when the model stops calling tools and writes text, that text
is the answer. No `submit` tool is offered. This costs one request fewer and
matches what models are trained to do.

**Every other signature** (several outputs, one that is not text, or one text
output with a constraint such as an enum, a pattern or an answer shape) gets a
`submit` tool whose parameters are the outputs, as in DSPy. Calling it with
valid values ends the turn; values that do not fit the signature are recorded
as that call's error, and the loop goes on. The name `submit` is reserved.

The one-text-output rule has a consequence to design for: any step that
writes text and calls no tool has answered. A model that says what it is
about to do, instead of doing it, has given that sentence as its answer.
A constrained output never takes that path: its allowed values are in
`submit`'s schema, and text is not an answer to it.

### 3. An interrupted turn gets one last request

A turn is interrupted when it reaches `max_iters`, when a step's request or
parse fails, or when a step gives neither a tool call nor an answer. Rather
than return nothing, Imp makes one more request:

- With `submit`, the request names `submit` as the required tool, as DSPy
  does (`:forced_submit`). If the provider cannot honour that, a typed
  extractor with no tools reads the history and fills the outputs
  (`:extracted`).
- With one text output, the request is an ordinary step, same tools, and its
  text is the answer (`:last_text`). Tool calls in it are not run; they are
  listed in `unexecuted_tool_calls`.

If the last request does not produce an answer either, the turn ends
`:incomplete`. That is still `{:ok, prediction}`, carrying the history and a
`termination_cause`, and `Imp.Prediction.complete?/1` is false for it; a turn
without an answer is never reported complete.

Imp adds nothing to that request unless you pass `last_request_note:`, one
line of your own text, sent as a user message and kept in the history.

A request refused because the context window is full is different. Imp first
retries with older episodes left out of the prompt (see below); if the request
still does not fit, another would be refused the same way, so the turn ends at
once, without a last request.

### 4. How it ended is metadata, never an output

The prediction's fields are exactly the signature's outputs, so an output can
be called anything, `history` included. The loop's own account lives in
`prediction.metadata`: `history`, `termination_reason`, and when the turn was
interrupted, `termination_cause`. `Imp.Prediction.complete?/1` is false
exactly when the turn has no answer.

## API walkthrough

### The loop

The escalation program routes a ticket and finds who is on call for it:

```elixir
on_call =
  Imp.tool(
    :on_call,
    "Look up the on-call engineer for a squad.",
    fn %{"team" => team} ->
      %{"atlas" => "Maya", "harbor" => "Tom", "beacon" => "Ines", "quill" => "Raj"}[team]
    end,
    schema: %{
      "type" => "object",
      "properties" => %{"team" => %{"type" => "string", "enum" => ["atlas", "harbor", "beacon", "quill"]}},
      "required" => ["team"]
    }
  )

escalation =
  Imp.signature(
    "ticket -> team: enum[atlas,harbor,beacon,quill], contact: string",
    "Find the squad that owns the ticket and its on-call engineer. " <>
      "atlas owns money, harbor the platform, beacon identity, quill the product."
  )
```

With `gpt-5.4-mini`, in three runs of six the model called `on_call` for atlas
and then `submit`:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

escalate = Imp.react(escalation, [on_call], lm: lm, max_iters: 5)
{:ok, prediction} = Imp.call(escalate, %{ticket: "We were charged twice this month."})

{Imp.get(prediction, :team), Imp.get(prediction, :contact), prediction.metadata.termination_reason}
#=> {"atlas", "Maya", :submit}
```

In the other three it submitted atlas without calling the tool, the turn
ended in the forced `submit`, and `contact` came back as `""` or `"unknown"`.
The type check accepts any string; it cannot tell that the model never looked.

In a tool loop the model reads the task's instructions, the tools, and the
history. The descriptions of your output fields reach it only inside the
`submit` tool's parameters. Put what the model needs to decide, such as what
the squads own, in the instructions. With the squad meanings in the `team`
field's description instead, the same model called `on_call` for all four
squads before submitting in five runs of six, and submitted harbor in one.

A scripted model shows the loop without a provider. Each step is either tool
calls or text:

```elixir
script = fn steps ->
  {:ok, agent} = Agent.start_link(fn -> steps end)

  Imp.LM.Static.new(
    handler: fn _messages, _opts ->
      Agent.get_and_update(agent, fn
        [step | rest] -> {step, rest}
        [] -> {%{tool_calls: []}, []}
      end)
    end
  )
end

lm =
  script.([
    %{next_thought: "A double charge is money, so atlas.", tool_calls: [%{name: "on_call", arguments: %{"team" => "atlas"}}]},
    %{tool_calls: [%{name: "submit", arguments: %{"team" => "atlas", "contact" => "Maya"}}]}
  ])

{:ok, prediction} = Imp.call(Imp.react(escalation, [on_call], lm: lm), %{ticket: "We were charged twice this month."})

{Imp.get(prediction, :team), Imp.get(prediction, :contact), prediction.metadata.termination_reason}
#=> {"atlas", "Maya", :submit}
```

### The history

Each entry holds the step's `next_thought`, its `tool_calls`, and its
`tool_call_results`, each result paired with its call's ID; the final entry
also holds the submitted outputs.

```elixir
for step <- prediction.metadata.history.messages,
    call <- step.tool_calls.tool_calls,
    do: call.name
#=> ["on_call", "submit"]
```

To continue the conversation, pass the history back:

~~~elixir
Imp.call(escalate, %{ticket: "It happened again today.", history: prediction.metadata.history})
~~~

The history keeps provider reasoning data needed to continue a turn, and
tool results in full, so store it privately. `Imp.History.redact/1` returns a
copy safe for logs.

### A text answer

A signature with one text output ends when the model writes text:

```elixir
lm =
  script.([
    %{tool_calls: [%{name: "on_call", arguments: %{"team" => "atlas"}}]},
    %{next_thought: "Maya from atlas is looking at the duplicate charge.", tool_calls: []}
  ])

reply = Imp.react(Imp.signature("ticket -> reply", "Tell the customer who is handling their ticket."), [on_call], lm: lm)
{:ok, prediction} = Imp.call(reply, %{ticket: "We were charged twice this month."})

{Imp.get(prediction, :reply), prediction.metadata.termination_reason}
#=> {"Maya from atlas is looking at the duplicate charge.", :answered}
```

That is also how a turn ends when the model narrates instead of acting. Given
"I can't log in after resetting my password." and instructions to look up who
is on call before replying, `gpt-5.4-mini` called the tool and named Ines in
one run of six. In the other five it wrote text without calling the tool, and
that text was the answer: twice a sentence about what it was going to do
("I'm looking into this now and will let you know who's on call for the team
handling login issues."), twice the tool call or its arguments written out as
JSON, and once nothing. When an
answer has to follow a tool call, give the signature a second output, so the
turn ends only through `submit`, or end it from the tool with `finish_on:`.

### Ending the turn from a tool

`finish_on:` maps a tool name to a function of the call's arguments, its
result and the turn's inputs. Returning `{:finish, outputs}` ends the turn
with those outputs, checked against the signature as a `submit` would be;
`:continue` lets the loop go on.

```elixir
lm = script.([%{tool_calls: [%{name: "on_call", arguments: %{"team" => "beacon"}}]}])

page_and_stop =
  Imp.react(escalation, [on_call],
    lm: lm,
    finish_on: %{
      on_call: fn %{"team" => team}, contact, _inputs ->
        {:finish, %{team: team, contact: contact}}
      end
    }
  )

{:ok, prediction} = Imp.call(page_and_stop, %{ticket: "I can't log in."})

{Imp.get(prediction, :contact), prediction.metadata.termination_reason, prediction.metadata.finished_by_tool}
#=> {"Ines", :finished_by_tool, "on_call"}
```

When one step calls several finishing tools, the first in call order ends
the turn; the others still run and are recorded, and a `submit` in the same
step wins.

### Why a turn ended

`termination_reason` says how the turn ended:

| Reason | Meaning |
| --- | --- |
| `:answered` | one text output: a step wrote the answer |
| `:submit` | the model called `submit` with valid outputs |
| `:finished_by_tool` | a `finish_on` function finished the turn; `finished_by_tool` names the tool |
| `:forced_submit` | interrupted; the last request, with `submit` required, answered |
| `:extracted` | interrupted; the provider could not require `submit`, and the extractor answered |
| `:last_text` | interrupted; one text output, and the last request's text is the answer |
| `:incomplete` | interrupted, and there is no answer |

When the turn was interrupted, `termination_cause` says why:

| Cause | Meaning |
| --- | --- |
| `:max_iters` | the step budget ran out |
| `:parse_error` | a step's reply could not be read |
| `:prediction_error` | a step's request failed |
| `:empty_tool_calls` | with `submit`: a step called no tool |
| `:context_window_exceeded` | the prompt no longer fits, even with old episodes left out |
| `:deadline_exceeded` | the process's `Imp.Deadline` passed |

For `:incomplete`, `termination_error` holds the redacted errors of the
requests that failed.

```elixir
lm =
  script.([
    %{tool_calls: [%{name: "on_call", arguments: %{"team" => "atlas"}}]},
    %{tool_calls: [%{name: "submit", arguments: %{"team" => "atlas", "contact" => "Maya"}}]}
  ])

{:ok, prediction} =
  Imp.call(Imp.react(escalation, [on_call], lm: lm, max_iters: 1), %{ticket: "We were charged twice this month."})

{prediction.metadata.termination_reason, prediction.metadata.termination_cause, Imp.get(prediction, :contact)}
#=> {:forced_submit, :max_iters, "Maya"}
```

An enum output keeps `submit`, so text alone does not end the turn. A model
that only ever writes text is interrupted, the forced `submit` gets text too,
and the turn has no answer:

```elixir
lm =
  script.([
    %{next_thought: "team: atlas", tool_calls: []},
    %{next_thought: "team: atlas", tool_calls: []}
  ])

router = Imp.react(Imp.signature("ticket -> team: enum[atlas,harbor,beacon,quill]"), [on_call], lm: lm)
{:ok, prediction} = Imp.call(router, %{ticket: "We were charged twice this month."})

{prediction.metadata.termination_reason, prediction.metadata.termination_cause, Imp.Prediction.complete?(prediction)}
#=> {:incomplete, :empty_tool_calls, false}
```

`max_iters` is 20 by default; a call can override it with a `max_iters`
input.

### Tools, policies and authorization

`tool_policy:` limits which tools the model may call; a refused call is
recorded as an error and the model reads that it was not allowed. `submit` is
subject to the policy too, so a list policy must include `:submit`, or the
turn cannot finish with it. To ask a person or a service before each call,
run the program under `Imp.start_run/3` with `authorize:`, or serve it over
ACP. See [Tools and MCP](tools-and-mcp.md).

Unknown tools, calls that fail the schema, and tools that raise all become
error results in the history, and the model can respond to them on the next
step.

### A full context window

When the provider refuses a request because the context window is full, Imp
retries with the oldest earlier episodes of the history left out of the
prompt, up to eight times. The history itself keeps everything; only the
request is smaller. `context_projection` in the metadata counts what was left
out. The current turn's own tool results are never dropped. If the current
turn and the instructions alone do not fit, the turn ends `:incomplete` with
`termination_cause: :context_window_exceeded`.

### Coming from DSPy's ReAct and ReActV2

DSPy is replacing its trajectory-based `ReAct` with the structured-history
`ReActV2`, which becomes `dspy.ReAct` in DSPy 3.5. `Imp.react/3` is already
that design. The trajectory-based loop remains as `Imp.Predict.ReAct` for
programs that need it.

What matches DSPy's ReActV2: structured history replayed as native messages,
several tool calls per step, a `submit` tool generated from the outputs,
the forced `submit` when a turn is interrupted, and passing `history` back to
continue.

What differs:

- A signature with one text output has no `submit`; the model's text is the
  answer (`:answered`, and `:last_text` when interrupted).
- `finish_on:` lets a tool end the turn (`:finished_by_tool`).
- When the provider cannot require `submit`, an extractor fills the outputs
  (`:extracted`); a turn with no answer is `:incomplete`, with a cause.
- History, termination reason and cause are in `prediction.metadata`, not
  among the output fields.
- On a full context window, old episodes are left out of the prompt; DSPy's
  ReActV2 does not truncate.
- Tool policies and per-run authorization decide which calls run.

## Cross-links

- [Tools and MCP](tools-and-mcp.md): tools, policies, MCP servers, ACP.
- [Adapters](adapters.md): the Chat adapter renders the history and the
  step's instructions.
- [Signatures](signatures.md): the outputs that become `submit`'s
  parameters.
- `Imp.Predict.ReActV2`, `Imp.History`, `Imp.Prediction`: the reference.
