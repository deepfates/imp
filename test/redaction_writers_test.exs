defmodule Imp.RedactionWritersTest do
  use ExUnit.Case, async: true

  # Every writer of a report, checkpoint, saved program, export or experiment
  # result redacts the term it was given before converting it. A client,
  # retriever or OAuth struct hides its header values and URL secrets only
  # while it is still a struct, and a key that is a tuple, a list or a struct
  # is only seen before encoding, so a writer that converts first writes them
  # out. `Imp.Test.RedactionProbe` holds the probe value.

  alias Imp.Optimizer.Report
  alias Imp.Test.RedactionProbe, as: Probe

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

  @shaped "sk-proj-" <> String.duplicate("PrObE7f3A", 5)

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-redaction-writers-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = Probe.store(root)
    %{root: root, store: store, probe: Probe.value(store)}
  end

  defp assert_redacted(output, store), do: Probe.assert_redacted(output, store)

  test "redaction keeps each struct's type and its non-secret fields", %{probe: probe} do
    redacted = Imp.Redaction.redact_term(probe)

    assert %Imp.Retrievers.HTTP{headers: headers, url: url} = redacted.retriever
    assert headers == [{"X-Subscription-Token", "[REDACTED]"}, {"X-Probe-Custom", "[REDACTED]"}]
    assert url == "https://retriever.test/search?[REDACTED]"
    assert %Imp.Retrievers.HTTP{} = redacted.token_retriever
    assert %Imp.Clients.ReqLLM{} = redacted.lm
    assert %Imp.MCP.OAuth.Store{key: "[REDACTED]"} = redacted.store
    assert redacted.store.directory == probe.store.directory
    assert Enum.any?(Map.keys(redacted.keyed), &match?(%Imp.Retrievers.HTTP{}, &1))
  end

  # JSON writes a pair as a two-element list inside a list of pairs: decoded
  # tool results, config and ReqLLM options arrive that way.
  @list_pairs [
    {[["api_key", "PROBE-LIST-PAIR-VALUE-7F3A"]], "PROBE-LIST-PAIR-VALUE-7F3A"},
    {%{headers: [["X-Api-Key", "PROBE-LIST-HEADER-VALUE-7F3A"]]}, "PROBE-LIST-HEADER-VALUE-7F3A"},
    {%{"config" => [["password", "PROBE-LIST-PASSWORD-VALUE-7F3A"], ["model", "gpt"]]},
     "PROBE-LIST-PASSWORD-VALUE-7F3A"},
    {Jason.decode!(
       ~s({"req_http_options": [["headers", [["authorization", "PROBE-LIST-JSON-VALUE-7F3A"]]]]})
     ), "PROBE-LIST-JSON-VALUE-7F3A"}
  ]

  test "a pair written as a two-element list is redacted by every writer" do
    writers = [
      &Imp.Redaction.redact/1,
      &Imp.Redaction.redact_term/1,
      &Imp.Redaction.drop_credentials/1,
      &Report.json_safe/1,
      &Report.json_projection/1,
      &Report.dump(Report.new(optimizer: :probe, metadata: %{probe: &1})),
      &Imp.Saving.dump(Imp.predict("question -> answer", metadata: %{probe: &1}))
    ]

    for {value, secret} <- @list_pairs, writer <- writers do
      written = Probe.bytes(writer.(value))
      assert :binary.match(written, secret) == :nomatch, "#{inspect(value)} leaked"
    end

    assert Imp.Redaction.redact(%{"config" => [["password", "x"], ["model", "gpt"]]}) ==
             %{"config" => [["password", "[REDACTED]"], ["model", "gpt"]]}

    assert Imp.Redaction.drop_credentials([["password", "x"], ["model", "gpt"]]) ==
             [["model", "gpt"]]
  end

  test "a list of names is data, not a pair" do
    for names <- [[:api_key, :question], ["api_key", "question"], ["token", "question"]] do
      assert Imp.Redaction.redact(names) == names
      assert Imp.Redaction.redact_term(names) == names
      assert Imp.Redaction.drop_credentials(names) == names
    end

    :ok = Imp.Optimizer.Parameter.validate_value!(%{"input_keys" => ["api_key", "question"]})
  end

  test "a string key shaped like a credential is redacted" do
    written = Probe.bytes(Report.json_safe(%{@shaped => 1, "model" => "gpt"}))
    assert :binary.match(written, @shaped) == :nomatch
    assert :binary.match(written, "model") != :nomatch
  end

  test "an Avatar tool schema's required names survive saving" do
    runner = fn args -> args end
    registry = Imp.Saving.Registry.new(lookup_runner: runner)

    schema = %{
      "type" => "object",
      "properties" => %{"api_key" => %{"type" => "string"}, "query" => %{"type" => "string"}},
      "required" => ["api_key", "query"]
    }

    avatar =
      Imp.avatar("question -> answer", [Imp.tool(:lookup, "lookup", runner, schema: schema)])

    restored =
      avatar
      |> Imp.dump(registry: registry)
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.load!(registry: registry)

    assert [%{schema: %{"required" => ["api_key", "query"]}}] = Map.values(restored.tools)
  end

  # An atom that spells a credential is written as the redaction marker, and a
  # fresh VM that has not loaded `Imp.Redaction` still reads it back.
  @tag :tmp_dir
  test "a report and a GRPO checkpoint holding the redacted atom load in a fresh VM",
       %{tmp_dir: tmp_dir} do
    shaped_atom = String.to_atom(@shaped)
    report_path = Path.join(tmp_dir, "report.json")
    grpo_path = Path.join(tmp_dir, "grpo.json")

    report = Report.new(optimizer: nil, metadata: %{"note" => shaped_atom})
    File.write!(report_path, report |> Report.dump() |> Jason.encode!())
    :ok = Imp.Optimizer.GRPO.Checkpoint.save!(grpo_path, :running, %{"note" => shaped_atom})

    expression = """
    [report_path, grpo_path] = System.argv()
    report = report_path |> File.read!() |> Jason.decode!() |> Imp.Optimizer.Report.load!()
    checkpoint = Imp.Optimizer.GRPO.Checkpoint.load!(grpo_path)
    IO.inspect({report.metadata, checkpoint.data})
    """

    args =
      "_build/test/lib/*/ebin"
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])
      |> Kernel.++(["-e", expression, report_path, grpo_path])

    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ ~s({%{"note" => :"[REDACTED]"}, %{"note" => :"[REDACTED]"}})
    refute output =~ @shaped
  end

  test "keys that redact to the same term keep one entry" do
    redacted = Imp.Redaction.redact_term(%{{:note, @shaped} => 1, {:note, @shaped <> "x"} => 2})
    assert [{{:note, "[REDACTED]"}, value}] = Map.to_list(redacted)
    assert value in [1, 2]
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

  test "an image's data is redacted when it is written" do
    image = %Imp.Adapter.Types.Image{data: @shaped, mime_type: "image/png", metadata: %{}}
    written = Probe.bytes(Report.json_safe(%{image: image}))
    assert :binary.match(written, @shaped) == :nomatch
    assert :binary.match(written, "image/png") != :nomatch
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

  # The export's own conversion names every key, so the probe goes in without
  # its tuple-keyed map.
  test "an evaluation's JSON and CSV exports", %{root: root, probe: probe, store: store} do
    probe = Map.delete(probe, :keyed)
    example = Imp.example(question: "q", answer: "a", note: @shaped, probe: probe)

    result = %Imp.Evaluate.Result{
      score: 1.0,
      rows: [%{example: example, prediction: Imp.Prediction.new(%{answer: "a"}), score: 1.0}],
      errors: []
    }

    for {save, name} <- [
          {&Imp.Evaluate.Result.save_as_json/2, "rows.json"},
          {&Imp.Evaluate.Result.save_as_csv/2, "rows.csv"}
        ] do
      path = Path.join(root, name)
      :ok = save.(result, path)
      written = File.read!(path)
      assert Probe.leaked(written, store) == []
      assert written =~ "retriever.test/search"
    end
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
    assert Probe.leaked(candidate["metadata"], store) == []
    assert :binary.match(Probe.bytes(candidate["metadata"]), "retriever.test/search") != :nomatch
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

  # A two-element list is a pair only as a tuple or an entry the codec tagged
  # as one. An input named `api_key` is data: the program loads back with its
  # input keys and metadata lists as they were.
  test "an input named api_key survives saving and loading", %{root: root} do
    demo =
      Imp.example(api_key: "which header?", question: "q")
      |> Imp.with_inputs([:api_key, :question])

    program =
      "api_key, question -> answer"
      |> Imp.predict(metadata: %{notes: [:api_key, :question], labels: ["token", "question"]})
      |> Imp.Predict.with_demos([demo])

    path = Path.join(root, "api-key-input.json")
    :ok = Imp.save!(program, path)
    loaded = Imp.Saving.read!(path)

    assert [%Imp.Example{input_keys: [:api_key, :question]}] = loaded.demos
    assert loaded.metadata.notes == [:api_key, :question]
    assert loaded.metadata.labels == ["token", "question"]

    candidate = Imp.Optimizer.Artifact.candidate("c1", program)
    restored = Imp.Saving.load!(candidate["program"])
    assert [%Imp.Example{input_keys: [:api_key, :question]}] = restored.demos
    assert restored.metadata.notes == [:api_key, :question]

    knn = Imp.Predict.KNN.new(1, [demo], vectorizer: Imp.Embeddings.BagOfWords)

    assert [%Imp.Example{input_keys: [:api_key, :question]}] =
             knn |> Imp.Saving.dump() |> Imp.Saving.load!() |> Map.fetch!(:trainset)
  end

  # The candidates are the optimized artifacts and are kept as they are; side
  # information is redacted.
  test "an Optimize Anything result", %{probe: probe, store: store} do
    result = %Imp.Optimize.Anything.Result{
      candidates: [%{"config" => "key: " <> @shaped}],
      parents: [[]],
      validation_scores: [1.0],
      validation_subscores: [%{}],
      candidate_side_information: [%{probe: probe}],
      instance_frontier: %{},
      discovery_evaluation_counts: [0],
      checkpoint: %{}
    }

    written = Imp.Optimize.Anything.Result.to_map(result)
    assert Probe.leaked(written["candidate_side_information"], store) == []
    assert :binary.match(Probe.bytes(written["candidates"]), @shaped) != :nomatch
  end

  # A trajectory refuses a struct it does not know and a key that is not an
  # atom or a string, so no part of the probe but its text reaches a playbook
  # checkpoint; the text is redacted.
  test "an optimizer trajectory, as a playbook checkpoint holds it", %{probe: probe, store: store} do
    trajectory = fn metadata ->
      struct(Imp.Optimizer.Trajectory,
        index: 0,
        example: %{question: "q"},
        prediction: %{answer: "a"},
        score: 1.0,
        metadata: metadata
      )
    end

    dumped = Imp.Optimizer.Trajectory.dump(trajectory.(%{note: @shaped}))
    assert Probe.leaked(dumped, store) == []

    for part <- [%{retriever: probe.retriever}, probe.keyed] do
      assert_raise Imp.Optimizer.Trajectory.DecodeError, fn ->
        Imp.Optimizer.Trajectory.dump(trajectory.(part))
      end
    end

    # The refusal names the key by its type, not by what it holds.
    error =
      assert_raise Imp.Optimizer.Trajectory.DecodeError, fn ->
        Imp.Optimizer.Trajectory.dump(trajectory.(%{{:api_key, "PROBE-REFUSED-KEY-7F3A"} => 1}))
      end

    refute Exception.message(error) =~ "PROBE-REFUSED-KEY-7F3A"
    assert Exception.message(error) =~ "a tuple of 2 elements"
  end

  # A session's history is redacted except the provider's reasoning
  # continuation, which a resumed session sends back unmodified.
  test "an ACP session record", %{root: root, probe: probe, store: store} do
    session_id = "imp_" <> String.duplicate("a", 24)
    # The reasoning holds a credential shape, which only its key keeps.
    reasoning = @shaped
    metadata = %{cwd: root, meta: %{}}
    :ok = Imp.ACP.SessionStore.create(root, session_id, metadata)

    history =
      Imp.History.new([
        %{
          question: "q",
          answer: "a",
          probe: probe,
          trajectory: [
            %{role: :assistant, reasoning_content: reasoning, reasoning_details: [reasoning]}
          ]
        }
      ])

    transcript = [%{"user" => "q " <> @shaped, "assistant" => "a"}]
    :ok = Imp.ACP.SessionStore.persist(root, session_id, metadata, history, transcript)

    [record] = Path.wildcard(Path.join(root, "**/#{session_id}*"))
    written = File.read!(record)
    assert written =~ "retriever.test/search"

    leaked = Probe.leaked(String.replace(written, reasoning, ""), store)
    assert leaked == []
    assert length(String.split(written, reasoning)) == 3

    {:ok, restored} = Imp.ACP.SessionStore.load(root, session_id, root)
    {:ok, history} = Imp.ACP.SessionStore.load_history(restored.history)
    [turn] = Imp.History.messages(history)
    [step] = turn.trajectory
    assert step.reasoning_content == reasoning
    assert step.reasoning_details == [reasoning]
  end
end
