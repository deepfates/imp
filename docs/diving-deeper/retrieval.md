# Retrieval

## Intent

A model knows only what is in its prompt. Retrieval puts the right part of
what *you* know there: your squad charters, your runbooks, your product docs.
Imp has three pieces for it. A **retriever** turns a query into documents.
`Imp.retrieve/3` calls any retriever the same way. `Imp.rag/3` wraps a
program so that each call retrieves first and hands the documents to the
program as a context field.

Read this when a program keeps guessing at facts you could have told it, or
when you are moving a DSPy RAG program to Imp.

## Design decisions

### 1. A retriever is a function or a struct

The smallest retriever is a function of the query and options that returns
`{:ok, documents}`. When a retriever needs state, such as a client, an index
or a URL, it is a struct whose module implements the `Imp.Retrieve`
behaviour. Documents are maps with a `:text` field, plus whatever else you
keep: an `:id`, a `:score`, metadata. Anything that can search can be a
retriever in a few lines, and there is no base class to fit.

### 2. Retrieval wraps a program; it is not a step the model sees

`Imp.rag/3` takes an ordinary program whose signature has a context input.
On each call it reads the query field, retrieves, joins the documents'
text into that context field, and calls the program. The wrapped program is
still just a program: you can evaluate it, optimize it and read its prompt.
The retrieval itself is ordinary code, and the model never decides whether
it happens.

### 3. What was retrieved travels with the answer

Each prediction from a RAG program carries `metadata.retrieval`: the query,
the documents, how many there were, and what each hop found. When the answer is wrong, you can see
whether retrieval found the wrong document or the model misread the right
one. Those are different fixes.

### 4. The model is explicit, and so is the retriever

DSPy has a global retriever setting that `dspy.Retrieve` reads. In Imp a RAG
program holds the retriever it was built with, the way a program holds its
model. Nothing is looked up from ambient state, and two programs on one node
can search two different stores.

### 5. A retrieval failure is an error, not an empty context

When a retriever returns an error, raises, or returns something that is not a
list of documents, `Imp.retrieve/3` returns `{:error, reason}` and a RAG
program returns that error without calling the model. Asking the model with
an empty context would give a confident answer to the wrong question.

### 6. Only the in-memory retriever is saved with a program

A RAG program over `Imp.memory/2` saves and loads whole, documents
included. Any other retriever is code your application builds, with the URL
and credentials it needs at run time, so saving a RAG program with one
refuses rather than writing half a program.

### 7. An agent retrieves through a tool

A fixed retrieve-then-answer step suits a question with one lookup. When the
model should decide what to look up, and how many times, give an agent a
search tool that calls a retriever. See [ReAct](react.md).

### 8. Embeddings are yours to choose

`Imp.memory/2` matches words, which is deterministic and free and misses
paraphrase. The Weaviate and Databricks retrievers ask a vector search
service, which ranks by meaning on its side. For retrieval by meaning over
your own documents, compute embeddings with any provider and rank by
similarity in your retriever. On the example below, that was the difference
between 50–70% and 85–90%.

## API walkthrough

### Retrievers and `Imp.retrieve/3`

`Imp.memory/2` is an in-memory retriever that ranks documents by the words
they share with the query:

```elixir
charters = [
  %{
    id: "atlas",
    text: "atlas owns money: charges, refunds, invoices, plans, taxes, receipts."
  },
  %{id: "harbor", text: "harbor owns the platform: outages, errors, latency, queues."},
  %{
    id: "beacon",
    text: "beacon owns identity: accounts, sign-in, SSO, sessions, permissions."
  },
  %{
    id: "quill",
    text: "quill owns the product: feature requests, how-to questions, docs."
  }
]

retriever = Imp.memory(charters, k: 2)

{:ok, docs} =
  Imp.retrieve(retriever, "Our SSO sign-in loops back to the login page.", k: 1)

Enum.map(docs, &{&1.id, &1.score})
#=> [{"beacon", 3}]
```

It returns at most `k` documents and leaves out any that share no word with
the query, so a query that matches nothing gets `{:ok, []}` and the program
gets no context.

A function is a retriever:

```elixir
echo = fn query, opts -> {:ok, [%{text: "You asked: " <> query, k: opts[:k]}]} end

Imp.retrieve(echo, "refunds", k: 2)
#=> {:ok, [%{text: "You asked: refunds", k: 2}]}
```

So is a struct whose module implements `Imp.Retrieve`:

```elixir
defmodule Tickets.RunbookIndex do
  @behaviour Imp.Retrieve

  defstruct runbooks: %{}

  def new(runbooks), do: %__MODULE__{runbooks: runbooks}

  @impl true
  def retrieve(%__MODULE__{runbooks: runbooks}, query, _opts) do
    docs =
      for {topic, text} <- runbooks,
          String.contains?(String.downcase(query), topic),
          do: %{id: topic, text: text}

    {:ok, docs}
  end
end

index = Tickets.RunbookIndex.new(%{"webhook" => "Replay failed webhooks from the dashboard."})

Imp.retrieve(index, "Webhooks stopped arriving at 3am.")
#=> {:ok, [%{id: "webhook", text: "Replay failed webhooks from the dashboard."}]}
```

Failures come back as values:

```elixir
Imp.retrieve(fn _query, _opts -> {:error, :index_offline} end, "refunds")
#=> {:error, :index_offline}

Imp.retrieve(fn _query, _opts -> raise "connection refused" end, "refunds")
#=> {:error, {:retriever_failed, :anonymous_retriever, %RuntimeError{message: "connection refused"}}}
```

### `Imp.rag/3`

Wrap a router whose signature takes a `context`. The scripted model here
routes to atlas only when atlas's charter is in its prompt:

```elixir
scripted =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "atlas owns money", do: %{team: "atlas"}, else: %{team: "harbor"}
    end
  )

router =
  Imp.predict("ticket, context -> team: enum[atlas,harbor,beacon,quill]", lm: scripted)

routed = Imp.rag(router, retriever, query_field: :ticket, k: 1)

{:ok, prediction} = Imp.call(routed, %{ticket: "I was charged twice for plans I cancelled."})
{Imp.get(prediction, :team), Enum.map(prediction.metadata.retrieval.docs, & &1.id)}
#=> {"atlas", ["atlas"]}
```

Options: `query_field:` (default `:question`; a list joins several fields),
`context_field:` (default `:context`), `k:` (default 3, and it overrides the
retriever's own `k`), and `hops:`. With `hops: 2` or more, each hop searches
again with the query plus the text found so far, for questions whose answer
takes two lookups. Earlier finds are not excluded from later searches, so
with a small `k` a hop can return a document it already has; the context
lists each document once.

A retriever error stops the call before the model is asked:

```elixir
offline =
  Imp.rag(router, fn _query, _opts -> {:error, :index_offline} end,
    query_field: :ticket
  )

Imp.call(offline, %{ticket: "I was charged twice for plans I cancelled."})
#=> {:error, :index_offline}
```

### With a real model

The router from the README, given each ticket's closest squad charter, found
first by shared words and then by meaning. Imp ships the charters with the
tutorial data:

~~~elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

data =
  :imp
  |> Application.app_dir("priv/tutorial/support_tickets.json")
  |> File.read!()
  |> Jason.decode!()

charters = for text <- data["conventions"], do: %{text: text}

test =
  for %{"ticket" => ticket, "team" => team} <- data["test"],
      do: Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)

router =
  "ticket, context -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

by_words = Imp.rag(router, Imp.memory(charters), query_field: :ticket, k: 1)

embed = fn texts ->
  {:ok, vectors} =
    ReqLLM.embed("openai:text-embedding-3-small", texts,
      api_key: System.fetch_env!("OPENAI_API_KEY")
    )

  vectors
end

indexed = Enum.zip(charters, embed.(Enum.map(charters, & &1.text)))

by_meaning = fn query, opts ->
  [query_vector] = embed.([query])

  docs =
    indexed
    |> Enum.map(fn {doc, vector} ->
      Map.put(doc, :score, Enum.zip_with(query_vector, vector, &*/2) |> Enum.sum())
    end)
    |> Enum.sort_by(&(-&1.score))
    |> Enum.take(Keyword.get(opts, :k, 1))

  {:ok, docs}
end

Imp.evaluate(by_words, test, Imp.exact_match(:team)).score
#=> 0.55

Imp.evaluate(
  Imp.rag(router, by_meaning, query_field: :ticket, k: 1),
  test,
  Imp.exact_match(:team)
).score
#=> 0.9
~~~

Over three runs on the 20 test tickets, the router scored 0.2–0.4 without
context (the same router with the signature `ticket -> team`), 0.5–0.7 with
the charter chosen by shared words, and 0.85–0.9 with the charter chosen by
meaning, for a few cents in all. By shared words, only 5 of the 20 tickets
get the right charter, and 5 share no word with any charter, so they get no
context at all. "Refund attempts fail with a gateway timeout error" is one of
those: "Refund" is not "refunds". The prompt the model saw:

~~~text
[[ ## ticket ## ]]
Refund attempts fail with a gateway timeout error.

[[ ## context ## ]]


Respond with a JSON object in the following order of fields: `team` (must be formatted as one of: atlas, harbor, beacon, quill).
~~~

With four charters, putting all of them in the prompt also works, and is
the right choice at that size. Retrieval earns its place when the documents
do not fit or would drown the ones that matter.

### Saving

A RAG program over `Imp.memory/2` saves like any other program. With any
other retriever, saving refuses:

```elixir
path = Path.join(System.tmp_dir!(), "routed.json")

try do
  Imp.save!(
    Imp.rag(Imp.predict("ticket, context -> team"), echo, query_field: :ticket),
    path
  )
rescue
  error in ArgumentError ->
    Exception.message(error) =~ "only Imp.Retrieve.Memory is portable"
end
#=> true
```

A saving registry does not cover retrievers. Save the wrapped program
instead, and call `Imp.rag/3` on it again after loading, with a retriever
your application builds (see [Saving and artifacts](saving-and-artifacts.md)).

### Retrieval as a tool

For an agent, wrap a retriever in a tool and let the model search:

```elixir
search_charters =
  Imp.tool(
    :search_charters,
    "Find the squad charters that match a query.",
    fn %{"query" => query} ->
      {:ok, docs} = Imp.retrieve(retriever, query, k: 2)
      Enum.map_join(docs, "\n", & &1.text)
    end,
    schema: %{
      "type" => "object",
      "required" => ["query"],
      "properties" => %{"query" => %{"type" => "string"}}
    }
  )

Imp.Tool.call(search_charters, %{"query" => "refunds and invoices"})
#=> "atlas owns money: charges, refunds, invoices, plans, taxes, receipts."
```

Pass it to `Imp.react/3` with the agent's other tools.

### Nearest examples

`Imp.knn/3` finds the training examples closest to an input, by embedding.
`Imp.Embeddings.BagOfWords` is a deterministic stand-in; a function of
`(texts, opts)` returning `{:ok, vectors}` plugs in any real embedding model:

```elixir
trainset =
  for {ticket, team} <- [
        {"We were charged twice this month.", "atlas"},
        {"Webhooks stopped arriving at 3am.", "harbor"},
        {"Our SSO login loops back to the sign-in page.", "beacon"}
      ],
      do: Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)

knn = Imp.knn(1, trainset, vectorizer: Imp.Embeddings.BagOfWords)

Imp.nearest(knn, %{ticket: "I was charged for a plan I cancelled."})
|> Enum.map(&Imp.get(&1, :team))
#=> ["atlas"]
```

`Imp.Optimizer.KNNFewShot` uses the same search to choose demos for each
call; see [Choosing an optimizer](choosing-an-optimizer.md).

### External stores

`Imp.Retrievers.HTTP` posts the query to a search endpoint and maps the JSON
it returns to documents, with timeouts and retries on 429 and 5xx responses;
`body_builder:` and `response_mapper:` adapt it to any API.
`Imp.Retrievers.Weaviate` and `Imp.Retrievers.Databricks` are built on it.
Pass credentials in `headers:` (or, for Databricks, `token:`) when you build
them, from runtime configuration.

### Coming from DSPy

| DSPy | Imp |
| --- | --- |
| `dspy.configure(rm=...)`, `dspy.Retrieve(k=3)(query)` | `Imp.retrieve(retriever, query, k: 3)`, with the retriever passed in |
| A `forward` that retrieves, then calls a predictor | `Imp.rag(program, retriever, query_field: :question)` |
| `dspy.retrievers.Embeddings`, `dspy.ColBERTv2` | a retriever function over your embeddings, or `Imp.Retrievers.HTTP` for a search service |
| `dspy.KNN(k, trainset, vectorizer)` | `Imp.knn(k, trainset, vectorizer: ...)` |
| `dspy.Embedder` | an `Imp.Embeddings` module or a `(texts, opts)` function |

## Cross-links

- [Modules and composition](modules-and-composition.md): writing your own
  multi-step program when one retrieve-then-answer step is not enough.
- [ReAct](react.md) and [Tools and MCP](tools-and-mcp.md): agents that
  search through tools.
- [Metrics and evaluation](metrics-and-evaluation.md): measuring retrieval
  and answers together.
- `Imp.Retrieve`, `Imp.Predict.RAG`, `Imp.Embeddings` and the retrievers
  under `Imp.Retrievers` list every option.
