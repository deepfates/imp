defmodule Imp.RedactionWritersTest do
  use ExUnit.Case, async: true

  # Every writer of a report, checkpoint, saved program or experiment result
  # redacts the term it was given before converting it. A client, retriever or
  # OAuth struct hides its header values and URL secrets only while it is
  # still a struct, so a writer that converts first writes them out. The probe
  # below holds secrets that do not look like credentials: only the place each
  # one sits (a header, a URL's query, an OAuth store's key) hides it.

  alias Imp.Optimizer.Report

  defmodule InstructionOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__ do
      %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }
    end

    @impl true
    def run(%__MODULE__{}, program, _opts) do
      optimized =
        program
        |> Imp.ProgramParameters.put_instruction(:main, "Answer yes.")
        |> Report.attach(Report.new(optimizer: :probe, best_score: 1.0, candidate_count: 1))

      {:ok, optimized}
    end
  end

  @subscription "PROBE-SUBSCRIPTION-VALUE-7F3A"
  @custom "PROBE-CUSTOM-HEADER-VALUE-7F3A"
  @url_key "PROBE-URL-KEY-VALUE-7F3A"
  @url_token "PROBE-URL-TOKEN-VALUE-7F3A"
  @llm_header "PROBE-LLM-HEADER-VALUE-7F3A"
  @oauth_secret "PROBE-OAUTH-SECRET-VALUE-7F3A-0123456789"

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-redaction-writers-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = Imp.MCP.OAuth.store(directory: Path.join(root, "oauth"), secret: @oauth_secret)
    %{root: root, store: store, probe: probe(store)}
  end

  # The retrievers are built without their default body, response and sleep
  # functions: a function is not JSON, so the writers that encode JSON would
  # refuse the probe before redaction mattered.
  defp probe(store) do
    %{
      retriever:
        struct(Imp.Retrievers.HTTP,
          url: "https://retriever.test/search?key=" <> @url_key,
          headers: [{"X-Subscription-Token", @subscription}, {"X-Probe-Custom", @custom}]
        ),
      token_retriever:
        struct(Imp.Retrievers.HTTP, url: "https://retriever.test/search?token=" <> @url_token),
      lm:
        Imp.req_llm("openai:gpt-4o-mini",
          req_http_options: [headers: [{"X-Probe-Custom", @llm_header}]]
        ),
      store: store
    }
  end

  defp secrets(store), do: [@subscription, @custom, @url_key, @url_token, @llm_header, store.key]

  # Everything a writer produced, as bytes: a binary in a term appears in its
  # external form as the bytes it holds.
  defp bytes(output) when is_binary(output), do: output
  defp bytes(output), do: :erlang.term_to_binary(output)

  defp assert_redacted(output, store) do
    written = bytes(output)
    leaked = for secret <- secrets(store), :binary.match(written, secret) != :nomatch, do: secret
    assert leaked == [], "secret values written: #{inspect(leaked)}"

    # The non-secret fields remain: the URL's host and path, the header names,
    # the model and the store's directory.
    for kept <- [
          "retriever.test/search",
          "X-Subscription-Token",
          "X-Probe-Custom",
          "gpt-4o-mini",
          store.directory
        ] do
      assert :binary.match(written, kept) != :nomatch, "#{kept} is missing from the output"
    end
  end

  test "redaction keeps each struct's type and its non-secret fields", %{probe: probe} do
    redacted = Imp.Redaction.redact_term(probe)

    assert %Imp.Retrievers.HTTP{headers: headers, url: url} = redacted.retriever
    assert headers == [{"X-Subscription-Token", "[REDACTED]"}, {"X-Probe-Custom", "[REDACTED]"}]
    assert url == "https://retriever.test/search?[REDACTED]"
    assert %Imp.Retrievers.HTTP{} = redacted.token_retriever
    assert %Imp.Clients.ReqLLM{} = redacted.lm
    assert %Imp.MCP.OAuth.Store{key: "[REDACTED]"} = redacted.store
    assert redacted.store.directory == probe.store.directory
  end

  test "an optimizer report's dump", %{probe: probe, store: store} do
    report =
      Report.new(optimizer: :probe, candidates: [%{probe: probe}], metadata: %{probe: probe})

    assert_redacted(Report.dump(report), store)
    assert_redacted(Report.dump(report) |> Report.load!() |> Report.dump(), store)
  end

  test "the report's JSON projections", %{probe: probe, store: store} do
    assert_redacted(Report.json_safe(probe), store)
    assert_redacted(Report.json_projection(probe), store)
    assert_redacted(Report.json_safe({:probe, [probe]}), store)
  end

  test "an experiment result", %{root: root, probe: probe, store: store} do
    result = experiment_result()

    test_rows =
      Enum.map(result.test.rows, fn row ->
        %{row | example: Imp.Example.new(Map.put(Imp.Example.to_map(row.example), :probe, probe))}
      end)

    result = %{
      result
      | provenance: Map.put(result.provenance, :probe, probe),
        test: %{result.test | rows: test_rows, errors: [%{index: 0, reason: {:probe, probe}}]}
    }

    assert_redacted(Imp.Experiment.Result.to_map(result, include_rows: true), store)

    path = Path.join(root, "result.json")
    :ok = Imp.Experiment.Result.write!(result, path, include_rows: true)
    assert_redacted(File.read!(path), store)
  end

  defp experiment_result do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "yes"} end)
    program = Imp.predict("question -> answer", lm: lm)

    row = fn id ->
      Imp.example(id: id, question: id, answer: "yes") |> Imp.with_inputs(:question)
    end

    data =
      Imp.Experiment.Data.new(
        train: [row.("train-1")],
        selection: [row.("selection-1")],
        test: [row.("test-1")],
        id: :id
      )

    {:ok, result} =
      Imp.Experiment.check(program, %InstructionOptimizer{}, data, Imp.exact_match(:answer),
        artifact_id: "probe-v1",
        evaluation_options: [num_threads: 1]
      )

    result
  end

  test "the BetterTogether bootstrap diagnostics", %{probe: probe, store: store} do
    lm =
      Imp.LM.Static.new(model: "probe-base", handler: fn _messages, _opts -> %{answer: "a"} end)

    student = Imp.predict("question -> answer", lm: lm)
    trainer = fn _lm, _examples, _opts -> {:error, {:probe, probe}} end
    metric = Imp.exact_match(:answer)

    examples =
      for index <- 1..3 do
        Imp.example(question: "q#{index}", answer: "a") |> Imp.with_inputs(:question)
      end

    compiled =
      Imp.Optimizer.BetterTogether.new(metric, %{
        w: Imp.Optimizer.BootstrapFinetune.new(nil, trainer: trainer)
      })
      |> Imp.Optimizer.BetterTogether.compile(student, examples, nil,
        strategy: :w,
        valset_ratio: 0
      )

    assert [%{diagnostics: %{"optimizer" => "bootstrap_finetune"} = diagnostics}] =
             Report.fetch(compiled).errors

    assert_redacted(diagnostics, store)
  end

  test "an optimizer artifact's candidate report and metadata", %{probe: probe, store: store} do
    program = Imp.predict("question -> answer")
    candidate = Imp.Optimizer.Artifact.candidate("c1", program, report: %{probe: probe})
    assert_redacted(candidate["report"], store)

    # Header tuples are not JSON, so metadata that holds headers is refused;
    # a retriever without headers and an OAuth store are accepted.
    metadata = %{retriever: probe.token_retriever, store: store}
    candidate = Imp.Optimizer.Artifact.candidate("c2", program, metadata: metadata)
    written = bytes(candidate["metadata"])
    assert :binary.match(written, @url_token) == :nomatch
    assert :binary.match(written, store.key) == :nomatch
    assert :binary.match(written, "retriever.test/search") != :nomatch
  end

  test "a GRPO session checkpoint", %{root: root, probe: probe, store: store} do
    path = Path.join(root, "grpo.json")
    :ok = Imp.Optimizer.GRPO.Checkpoint.save!(path, :running, %{probe: probe})

    assert_redacted(File.read!(path), store)
    assert_redacted(Imp.Optimizer.GRPO.Checkpoint.load!(path), store)
  end

  test "a saved Predict's metadata and demos", %{root: root, probe: probe, store: store} do
    demo = Imp.example(question: "q", answer: "a", probe: probe)

    program =
      "question -> answer"
      |> Imp.predict(metadata: %{probe: probe})
      |> Imp.Predict.with_demos([demo])

    assert_redacted(Imp.Saving.dump(program), store)

    path = Path.join(root, "program.json")
    :ok = Imp.save!(program, path)
    assert_redacted(File.read!(path), store)
  end

  test "a saved program's KNN examples and memory documents", %{probe: probe, store: store} do
    example = Imp.example(question: "q", answer: "a", probe: probe) |> Imp.with_inputs(:question)
    knn = Imp.Predict.KNN.new(1, [example], vectorizer: Imp.Embeddings.BagOfWords)
    assert_redacted(Imp.Saving.dump(knn), store)

    retriever = Imp.Retrieve.Memory.new([%{text: "doc", probe: probe}])
    rag = Imp.rag(Imp.predict("context, question -> answer"), retriever)
    assert_redacted(Imp.Saving.dump(rag), store)
  end
end
