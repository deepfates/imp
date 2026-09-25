# Tools and agents

The router guesses because it doesn't know what our squads own. One way to
fix that is to let it look it up. A **tool** is an Elixir function the model
may call; `Imp.react/3` builds an agent that calls tools until it has an
answer.

## A tool is a function

Each squad has a one-line charter. Here is a tool that returns one:

```elixir
charters = %{
  "atlas" => "atlas owns money: charges, refunds, invoices, plans, taxes, receipts.",
  "harbor" => "harbor owns the platform: outages, errors, latency, queues, and technical failures even when they involve payments or email delivery.",
  "beacon" => "beacon owns identity and trust: accounts, credentials, sessions, permissions, and data exposure, including routine lockouts.",
  "quill" => "quill owns the product experience: feature requests, how-to questions, and documentation."
}

charter =
  Imp.tool(
    :charter,
    "Read what a squad owns.",
    fn %{team: team} -> Map.get(charters, team, "There is no squad called #{team}.") end,
    schema: %{
      "type" => "object",
      "properties" => %{"team" => %{"type" => "string", "enum" => Map.keys(charters)}},
      "required" => ["team"]
    }
  )
```

The model sees the tool's name, its description, and its schema, the JSON
Schema of its arguments. As with signatures, the names are part of the
program: `charter` and `team` tell the model what the tool is for.

Imp checks the arguments against the schema before the function runs. A call
that doesn't fit becomes an observation the model can read and correct, not an
exception in our code.

## An agent that uses it

```elixir
agent =
  Imp.react(
    Imp.signature(
      "ticket -> team: enum[atlas,harbor,beacon,quill], reason: string",
      "Route the support ticket to the squad that owns it."
    ),
    [charter],
    lm: lm,
    max_iters: 5
  )

{:ok, prediction} =
  Imp.call(agent, %{ticket: "Refund attempts fail with a gateway timeout error."})

{Imp.get(prediction, :team), Imp.get(prediction, :reason)}
#=> {"atlas", "Refunds are a payments/money domain issue, and atlas owns refunds. The gateway timeout appears during refund attempts, but the underlying feature is refund processing rather than a general platform incident."}
```

This ticket is the hard kind: it mentions refunds, which are atlas's, but the
failure is a gateway timeout, and our charters give technical failures to
harbor even when they involve payments. The label says harbor. On this run the
agent weighed it and said atlas; on other runs it read harbor's charter and
said harbor. A tool gives the model the facts; it doesn't guarantee the model
applies them the way we would. That is why the next pages measure programs on
many tickets rather than judging them by one.

We added a `reason` output so we can see why it chose. The agent works in
steps: each step, the model either calls tools or finishes by calling
`submit`, a tool Imp adds whose arguments are the signature's outputs. Those
arguments are validated like any prediction, so the loop can't return a team
that doesn't exist. `max_iters` bounds the steps; a turn that runs out is made
to submit what it has.

## Reading the trajectory

The steps the agent took are in the prediction's metadata:

```elixir
for step <- prediction.metadata.history.messages,
    result <- step.tool_call_results do
  IO.puts("#{result.name}: #{inspect(result.result)}")
end
```

```text
charter: "atlas owns money: charges, refunds, invoices, plans, taxes, receipts."
charter: "harbor owns the platform: outages, errors, latency, queues, and technical failures even when they involve payments or email delivery."
charter: "beacon owns identity and trust: accounts, credentials, sessions, permissions, and data exposure, including routine lockouts."
charter: "quill owns the product experience: feature requests, how-to questions, and documentation."
submit: %{reason: "Refunds are a payments/money domain issue, and atlas owns refunds. The gateway timeout appears during refund attempts, but the underlying feature is refund processing rather than a general platform incident.", team: "atlas"}
```

Here the model read all four charters, then submitted. Other runs read only
one; the model decides. When an agent does something surprising, the
trajectory is the first thing to read.

## Keeping tools in bounds

A tool runs with whatever authority its function has. Keep authorization,
timeouts, and idempotency in the functions themselves, as you would for any
code a request can reach. When your code already knows which function to
call, call it directly; an agent is for when the model has to choose.

Tools can also come from an MCP server, a standard way for services to
publish tools to models: `Imp.MCP.connect/2` turns a server's tools into
`Imp.Tool` values that work here unchanged. A server may publish twenty tools
when a program should use two. `tool_policy:` names the tools a program may
call, and anything else is refused before it runs. `submit` is a tool like
the others, so the list must name it too:

~~~elixir
Imp.react(
  "question -> answer: string, source: string",
  imported.tools,
  lm: lm,
  tool_policy: ["search_docs", "read_page", :submit]
)
~~~

[Tools and MCP](../diving-deeper/tools-and-mcp.md) and
[ReAct](../diving-deeper/react.md) go further: tool schemas, policies, MCP
servers, and how the loop ends.

[Livebook 04](../../livebooks/04_tools_agents_mcp_rlm.livemd) runs tools,
ReAct, MCP imports and RLM in a notebook.

---

**Next:** [Composing programs →](composing-programs.md)
