defmodule OptimizerReportTest do
  use ExUnit.Case

  test "public optimizer identity loads in a fresh OS before its module" do
    root =
      Path.join(System.tmp_dir!(), "imp-report-atom-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "report.json")
    receipt = Path.join(root, "receipt")
    on_exit(fn -> File.rm_rf!(root) end)

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :better_together,
        best_score: 1.0,
        candidate_count: 1
      })

    File.write!(path, Jason.encode!(Imp.Optimizer.Report.dump(report)))

    code = """
    state = #{inspect(path)} |> File.read!() |> Jason.decode!()
    report = Imp.Optimizer.Report.load(state)
    File.write!(#{inspect(receipt)}, Atom.to_string(report.optimizer))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output == ""
    assert File.read!(receipt) == "better_together"
  end

  defmodule ErrorOptimizer do
    defstruct []

    @behaviour Imp.Optimizer

    @impl true
    def __optimizer__ do
      %{
        kind: :program,
        datasets: %{trainset: :required, validation: :optional},
        result: :program
      }
    end

    @impl true
    def run(%__MODULE__{}, _program, _opts), do: {:error, :optimizer_declined}
  end

  defmodule MultiPredictorProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]
    def update_optimizer_predictor(program, name, update), do: Map.update!(program, name, update)
  end

  defmodule ContextRetryLM do
    defstruct [:owner, fail_at_one?: false]

    def generate(_messages, _opts), do: {:error, :instance_required}

    def generate(%__MODULE__{owner: owner} = lm, messages, opts) do
      prompt = Enum.map_join(messages, "\n", & &1.content)
      example_count = length(Regex.scan(~r/Input Fields:/, prompt))
      send(owner, {:infer_rules_retry, example_count, prompt, opts[:rollout_id]})

      if example_count > 1 or lm.fail_at_one? do
        {:error, %Imp.ContextWindowExceededError{message: "controlled overflow"}}
      else
        {:ok,
         %{
           reasoning: "One example fits.",
           natural_language_rules: "Map France questions to Paris."
         }}
      end
    end
  end

  defp lm do
    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "[[ ## answer ## ]]\nParis" or prompt =~ "Always answer Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }
  end

  defp sets do
    train = [
      Imp.example(question: "France capital?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]

    dev = [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]

    {train, dev}
  end

  test "lossless term codec preserves structured tuple errors" do
    value = %{error: {:metric_error, {:provider, :offline}}, lineage: [nil, {:parent, 2}]}

    encoded = Imp.Optimizer.Report.encode_term(value)

    assert Jason.encode!(encoded) |> Jason.decode!() |> Imp.Optimizer.Report.decode_term() ==
             value
  end

  test "lossless term codec preserves atom and string map keys distinctly" do
    value = %{"alpha" => 2, alpha: 1}

    encoded = Imp.Optimizer.Report.encode_term(value)

    assert encoded["__imp_type__"] == "map"

    assert encoded
           |> Jason.encode!()
           |> Jason.decode!()
           |> Imp.Optimizer.Report.decode_term() == value
  end

  test "lossless term codec preserves improper provider metadata lists" do
    value = %{headers: [{"x-request-id", "req-1"} | "messages"]}

    encoded = Imp.Optimizer.Report.encode_term(value)

    assert encoded
           |> Jason.encode!()
           |> Jason.decode!()
           |> Imp.Optimizer.Report.decode_term() == value

    assert_raise ArgumentError, ~r/malformed Imp improper-list JSON tag/, fn ->
      Imp.Optimizer.Report.decode_term(%{
        "__imp_type__" => "improper_list",
        "heads" => [],
        "tail" => "messages"
      })
    end
  end

  test "public report serialization drops credential-bearing fields" do
    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :credential_probe,
        candidates: [%{api_key: "CANARY_REPORT_CANDIDATE", score: 1.0}],
        metadata: %{authorization: "CANARY_REPORT_METADATA", label: "kept"}
      })

    dumped = Imp.Optimizer.Report.dump(report)
    encoded = Jason.encode!(dumped)

    refute encoded =~ "CANARY_REPORT_CANDIDATE"
    refute encoded =~ "CANARY_REPORT_METADATA"
    assert encoded =~ "[REDACTED]"

    restored = Imp.Optimizer.Report.load(dumped)
    assert restored.candidates == [%{api_key: "[REDACTED]", score: 1.0}]
    assert restored.metadata == %{authorization: "[REDACTED]", label: "kept"}

    refute Jason.encode!(Imp.Optimizer.Report.json_safe(report)) =~ "CANARY_REPORT"
    refute Jason.encode!(Imp.Optimizer.Report.json_projection(report)) =~ "CANARY_REPORT"

    safe_value =
      Imp.Optimizer.Report.json_safe(%{
        api_key: "CANARY_REPORT_VALUE",
        nested: %{authorization: "CANARY_REPORT_NESTED"},
        label: "kept"
      })

    safe_json = Jason.encode!(safe_value)
    refute safe_json =~ "CANARY_REPORT_VALUE"
    refute safe_json =~ "CANARY_REPORT_NESTED"
    assert safe_json =~ "[REDACTED]"
  end

  test "plain JSON strings stay strings even when matching existing atoms" do
    assert Imp.Optimizer.Report.decode_term(%{"alpha" => "alpha"}) == %{
             "alpha" => "alpha"
           }

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: "alpha",
        metadata: %{"alpha" => "alpha"}
      })

    restored = report |> Imp.Optimizer.Report.dump() |> Imp.Optimizer.Report.load()

    assert restored.optimizer == "alpha"
    assert restored.metadata == %{"alpha" => "alpha"}
  end

  test "one-way JSON projections keep schema keys readable without silent collisions" do
    assert Imp.Optimizer.Report.json_projection(%{score: 1.0, output: %{answer: "ok"}}) ==
             %{"score" => 1.0, "output" => %{"answer" => "ok"}}

    assert_raise ArgumentError, ~r/projection contains colliding JSON key "alpha"/, fn ->
      Imp.Optimizer.Report.json_projection(%{"alpha" => 2, alpha: 1})
    end
  end

  test "lossless term codec tags non-JSON map keys" do
    value = %{0 => "zero", 1 => %{score: 0.75}, {:objective, 2} => :kept}

    assert value ==
             value
             |> Imp.Optimizer.Report.encode_term()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Imp.Optimizer.Report.decode_term()
  end

  test "optimizer report attributes reject atom/string collisions" do
    assert_raise ArgumentError, ~r/colliding attribute key "optimizer"/, fn ->
      Imp.Optimizer.Report.new(%{:optimizer => :one, "optimizer" => :two})
    end

    assert_raise ArgumentError,
                 ~r/optimizer report state contains colliding key "optimizer"/,
                 fn ->
                   Imp.Optimizer.Report.load(%{:optimizer => :one, "optimizer" => "two"})
                 end
  end

  test "term decoder rejects decoded key collisions and malformed tagged maps" do
    assert_raise ArgumentError, ~r/duplicate decoded key 1/, fn ->
      Imp.Optimizer.Report.decode_term(%{
        "__imp_type__" => "map",
        "entries" => [[1, "one"], [1, "duplicate"]]
      })
    end
  end

  test "term decoder rejects non-canonical tagged and report states" do
    assert_raise ArgumentError, ~r/malformed Imp atom JSON tag/, fn ->
      Imp.Optimizer.Report.decode_term(%{
        "__imp_type__" => "atom",
        "value" => "alpha",
        "extra" => true
      })
    end

    assert_raise ArgumentError, ~r/malformed Imp tuple JSON tag/, fn ->
      Imp.Optimizer.Report.decode_term(%{
        "__imp_type__" => "tuple",
        "items" => [],
        "extra" => true
      })
    end

    report_state = Imp.Optimizer.Report.dump(Imp.Optimizer.Report.new(optimizer: :alpha))

    assert_raise ArgumentError, ~r/malformed optimizer report state/, fn ->
      Imp.Optimizer.Report.load(Map.put(report_state, "extra", true))
    end

    assert_raise ArgumentError, ~r/malformed optimizer report state/, fn ->
      Imp.Optimizer.Report.load(Map.put(report_state, "candidate_count", "many"))
    end

    assert_raise ArgumentError, ~r/malformed Imp optimizer report JSON tag/, fn ->
      report_state
      |> Map.put("__imp_type__", "optimizer_report")
      |> Map.put("extra", true)
      |> Imp.Optimizer.Report.decode_term()
    end
  end

  test "random search attaches candidate history and best score" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.RandomSearch.new(candidates: 3, demos_per_candidate: 1)
      |> Imp.Optimizer.RandomSearch.compile(program, train, dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert %Imp.Optimizer.Report{
             optimizer: :random_search,
             best_score: 100.0,
             candidate_count: 6
           } =
             report

    assert Enum.all?(report.candidates, &Map.has_key?(&1, :score))
    assert report.metadata.candidate_seeds == [-3, -2, -1, 0, 1, 2]
  end

  test "upstream bootstrap random-search aliases delegate to the canonical optimizer" do
    metric = Imp.Metrics.exact_match(:answer)

    assert %Imp.Optimizer.RandomSearch{candidates: 2, demos_per_candidate: 1} =
             Imp.Optimizer.BootstrapRS.new(metric, candidates: 2, demos_per_candidate: 1)

    assert %Imp.Optimizer.RandomSearch{candidates: 3, demos_per_candidate: 2} =
             Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
               candidates: 3,
               demos_per_candidate: 2
             )
  end

  test "InferRules retains deterministic pre-induced rules for replay" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.InferRules.new(candidates: ["Always answer Paris."])
      |> Imp.Optimizer.InferRules.compile(program, [], dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :infer_rules
    assert report.metadata.implementation == :native_rule_induction
    assert report.metadata.explicit_candidates
    assert report.metadata.proposal_calls == 0
    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) =~ "Always answer Paris."
  end

  test "InferRules induces rules from observed values and selects them on validation data" do
    parent = self()

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "Map France questions to Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      )

    rule_lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(parent, {:infer_rules_prompt, messages, opts})

          %{
            reasoning: "The examples reveal a country-to-capital mapping.",
            natural_language_rules: "Map France questions to Paris."
          }
        end
      )

    train = [
      Imp.example(question: "France capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    dev = [
      Imp.example(question: "Which city is France's capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: task_lm)

    compiled =
      metric
      |> Imp.Optimizer.InferRules.new(
        rule_lm: rule_lm,
        num_candidates: 2,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )
      |> Imp.Optimizer.InferRules.compile(program, train, dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :infer_rules
    assert report.best_score == 1.0
    assert report.metadata.proposal_calls == 2
    assert report.metadata.baseline_protected
    assert report.metadata.trainset_size == 1
    assert report.metadata.validation_size == 1
    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) =~ "Map France"

    prompts =
      for _ <- 1..2 do
        assert_receive {:infer_rules_prompt, messages, opts}
        assert opts[:temperature] == 1.0
        Enum.map_join(messages, "\n", & &1.content)
      end

    assert Enum.all?(prompts, &(&1 =~ "question: France capital?"))
    assert Enum.all?(prompts, &(&1 =~ "answer: Paris"))
  end

  test "InferRules applies max_errors to public-facade candidate evaluation" do
    failing_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> raise "candidate task failure" end)

    dev = [
      Imp.example(question: "France capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    optimizer =
      Imp.Optimizer.InferRules.new(Imp.Metrics.exact_match(:answer),
        candidates: ["Map France questions to Paris."],
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        max_errors: 1
      )

    compiled =
      Imp.optimize!(
        Imp.predict("question -> answer", lm: failing_lm),
        optimizer,
        [],
        dev
      )

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.metadata.evaluation_max_errors == 1
    assert Enum.all?(report.candidates, &(&1.status == :error))

    assert Enum.all?(report.candidates, fn candidate ->
             candidate.error =~ "max_errors 1"
           end)
  end

  test "InferRules retries context overflows with one fewer trailing example" do
    parent = self()

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "Map France questions to Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      )

    train =
      for question <- ["France capital?", "Capital city of France?", "France's seat?"] do
        Imp.example(question: question, answer: "Paris") |> Imp.with_inputs(:question)
      end

    dev =
      [
        Imp.example(question: "Which city governs France?", answer: "Paris")
        |> Imp.with_inputs(:question)
      ]

    compiled =
      Imp.Optimizer.InferRules.new(Imp.Metrics.exact_match(:answer),
        rule_lm: %ContextRetryLM{owner: parent},
        num_candidates: 1,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )
      |> Imp.Optimizer.InferRules.compile(
        Imp.predict("question -> answer", lm: task_lm),
        train,
        dev
      )

    attempts =
      for _ <- 1..3 do
        assert_receive {:infer_rules_retry, count, prompt, rollout_id}
        assert prompt =~ "Given a set of examples, extract a list of 1 concise"
        {count, rollout_id}
      end

    assert attempts == [{3, 0}, {2, 0}, {1, 0}]
    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.best_score == 1.0
    assert report.metadata.proposal_calls == 1
    assert report.metadata.proposal_attempts == 3
    assert report.errors == []
    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) =~ "Map France"
  end

  test "InferRules records an exhausted one-example context retry and retains the baseline" do
    parent = self()

    train =
      for question <- ["France capital?", "Capital city of France?"] do
        Imp.example(question: question, answer: "Paris") |> Imp.with_inputs(:question)
      end

    dev =
      [
        Imp.example(question: "Which city governs France?", answer: "unknown")
        |> Imp.with_inputs(:question)
      ]

    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "unknown"} end)
      )

    compiled =
      Imp.Optimizer.InferRules.new(Imp.Metrics.exact_match(:answer),
        rule_lm: %ContextRetryLM{owner: parent, fail_at_one?: true},
        num_candidates: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )
      |> Imp.Optimizer.InferRules.compile(program, train, dev)

    assert_receive {:infer_rules_retry, 2, _prompt, 0}
    assert_receive {:infer_rules_retry, 1, _prompt, 0}

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.best_score == 1.0
    assert report.metadata.proposal_calls == 1
    assert report.metadata.proposal_attempts == 2
    assert report.metadata.status == :with_errors
    assert [%{stage: :rule_induction, error: "controlled overflow"}] = report.errors

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             program.signature.instructions
  end

  test "labeled few-shot reports selected demonstrations without scoring them" do
    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, train)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :labeled_few_shot
    assert report.best_score == nil
    assert report.candidate_count == 1
    assert report.metadata.requested_k == 1
    assert report.metadata.selected_count == 1
    assert [%{index: 0, selected?: true, example: example}] = report.candidates
    assert Imp.Example.get(example, :answer) == "Paris"
    assert length(compiled.demos) == 1
  end

  test "few-shot optimizers attach demos through wrapper programs" do
    {train, _dev} = sets()

    pot =
      "question -> answer"
      |> Imp.program_of_thought()
      |> then(
        &Imp.Optimizer.LabeledFewShot.compile(Imp.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%Imp.Example{}] = pot.predict.demos
    assert Imp.Optimizer.Report.fetch(pot).optimizer == :labeled_few_shot

    code_act =
      "question -> answer"
      |> Imp.code_act()
      |> then(
        &Imp.Optimizer.LabeledFewShot.compile(Imp.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%Imp.Example{}] = code_act.program_of_thought.predict.demos
    assert Imp.Optimizer.Report.fetch(code_act).optimizer == :labeled_few_shot

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> then(
        &Imp.Optimizer.LabeledFewShot.compile(Imp.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%Imp.Example{}] = rag.program.demos
    assert Imp.Optimizer.Report.fetch(rag).optimizer == :labeled_few_shot
  end

  test "instruction search helpers traverse wrapper programs" do
    pot =
      "question -> answer"
      |> Imp.program_of_thought()
      |> Imp.Optimizer.InstructionSearch.put_instruction("Answer briefly.")

    assert Imp.Optimizer.InstructionSearch.current_instruction(pot) == "Answer briefly."
    assert pot.signature.instructions == "Answer briefly."
    assert pot.predict.signature.instructions == "Answer briefly."

    code_act =
      "question -> answer"
      |> Imp.code_act()
      |> Imp.Optimizer.InstructionSearch.put_instruction("Use code sparingly.")

    assert Imp.Optimizer.InstructionSearch.current_instruction(code_act) == "Use code sparingly."
    assert code_act.program_of_thought.signature.instructions == "Use code sparingly."
    assert code_act.program_of_thought.predict.signature.instructions == "Use code sparingly."

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> Imp.Optimizer.InstructionSearch.put_instruction("Use retrieved context.")

    assert Imp.Optimizer.InstructionSearch.current_instruction(rag) == "Use retrieved context."
    assert rag.program.signature.instructions == "Use retrieved context."

    best_of_n =
      "question -> answer"
      |> Imp.predict()
      |> Imp.best_of_n(fn _example, _prediction -> 1.0 end, n: 1)
      |> Imp.Optimizer.InstructionSearch.put_instruction("Compare one answer exactly.")

    assert best_of_n.program.signature.instructions == "Compare one answer exactly."

    assert Imp.Optimizer.InstructionSearch.current_instruction(best_of_n) ==
             "Compare one answer exactly."

    with_playbook =
      "question -> answer"
      |> Imp.predict()
      |> Imp.with_playbook(Imp.Playbook.new(id: "instruction-search"))
      |> Imp.Optimizer.InstructionSearch.put_instruction("Use the active playbook.")

    assert [%{predictor: predictor}] = Imp.ProgramParameters.predictors(with_playbook)
    assert predictor.signature.instructions == "Use the active playbook."

    assert Imp.ProgramAccess.task_signature(with_playbook).instructions ==
             "Use the active playbook."
  end

  test "instruction search rejects unsupported and ambiguous program graphs instead of scoring no-ops" do
    assert_raise ArgumentError, ~r/exposes no optimizer predictor/, fn ->
      Imp.Optimizer.InstructionSearch.put_instruction(%URI{scheme: "https"}, "No-op")
    end

    multi = %MultiPredictorProgram{
      first: Imp.predict("question -> answer"),
      second: Imp.predict("question -> answer")
    }

    assert_raise ArgumentError, ~r/requires one predictor/, fn ->
      Imp.Optimizer.InstructionSearch.put_instruction(multi, "Ambiguous")
    end
  end

  test "instruction search updates wrapper task signatures as well as LM signatures" do
    pot =
      "x, context -> doubled"
      |> Imp.program_of_thought(output_field: :doubled)
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "double x"}]))
      |> Imp.Optimizer.InstructionSearch.put_instruction("Double with retrieved context.")

    assert pot
           |> Imp.ProgramAccess.task_signature()
           |> Map.fetch!(:instructions) == "Double with retrieved context."

    assert pot
           |> Imp.ProgramAccess.lm_signature()
           |> Map.fetch!(:instructions) == "Double with retrieved context."

    assert "x, context -> doubled" =
             pot
             |> Imp.ProgramAccess.task_signature()
             |> Imp.Signature.to_spec()

    assert "x, context -> program, tool, arguments" =
             pot
             |> Imp.ProgramAccess.lm_signature()
             |> Imp.Signature.to_spec()
  end

  test "instruction search optimizer metadata attaches through wrapper programs" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)

    program =
      "question, context -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Always answer Paris."
      ])

    assert compiled.program.metadata.trainset_size == 0
    assert compiled.program.metadata.candidate_count == 1
    assert Imp.Optimizer.Report.fetch(compiled).optimizer == :instruction_search
  end

  test "optimizer reports attach and fetch through wrapper programs" do
    report = Imp.Optimizer.Report.new(%{optimizer: :wrapper_probe, metadata: %{status: :ok}})

    pot = Imp.program_of_thought("question -> answer")
    pot = Imp.Optimizer.Report.attach(pot, report)
    assert Imp.Optimizer.Report.fetch(pot).optimizer == :wrapper_probe
    assert pot.predict.metadata.optimizer_report.metadata.status == :ok

    code_act = Imp.code_act("question -> answer")
    code_act = Imp.Optimizer.Report.attach(code_act, report)
    assert Imp.Optimizer.Report.fetch(code_act).optimizer == :wrapper_probe
    assert code_act.program_of_thought.predict.metadata.optimizer_report.metadata.status == :ok

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> Imp.Optimizer.Report.attach(report)

    assert Imp.Optimizer.Report.fetch(rag).optimizer == :wrapper_probe
    assert rag.program.metadata.optimizer_report.metadata.status == :ok
  end

  test "optimizer reports serialize with embedded examples and restore as reports" do
    {train, _dev} = sets()

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :labeled_few_shot,
        candidate_count: 1,
        candidates: [%{index: 0, selected?: true, example: hd(train)}],
        metadata: %{status: :ok, note: "keep strings as strings"}
      })

    restored =
      report
      |> Imp.Optimizer.Report.encode_term()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.Optimizer.Report.decode_term()

    assert %Imp.Optimizer.Report{} = restored
    assert restored.optimizer == :labeled_few_shot
    assert restored.metadata.status == :ok
    assert restored.metadata.note == "keep strings as strings"
    assert [%{example: example, selected?: true}] = restored.candidates
    assert %Imp.Example{} = example
    assert Imp.Example.get(example, :question) == "France capital?"
    assert Imp.Example.inputs(example).fields == %{question: "France capital?"}
  end

  test "optimizer reports accept decoded attrs and reject malformed attrs clearly" do
    report =
      Imp.Optimizer.Report.new(%{
        "optimizer" => "provider_search",
        "best_score" => 0.75,
        "candidate_count" => 2,
        "candidates" => [%{"score" => 0.75}],
        "errors" => [%{"error" => "candidate failed"}],
        "metadata" => %{"source" => "decoded-json"}
      })

    assert report.optimizer == "provider_search"
    assert report.best_score == 0.75
    assert report.candidate_count == 2
    assert report.candidates == [%{"score" => 0.75}]
    assert report.errors == [%{"error" => "candidate failed"}]
    assert report.metadata == %{"source" => "decoded-json"}

    assert Imp.Optimizer.Report.new(optimizer: :keyword_report).optimizer == :keyword_report

    assert_raise ArgumentError,
                 ~r/Imp.Optimizer.Report\.new\/1 expects a map or keyword list/,
                 fn ->
                   Imp.Optimizer.Report.new(:not_attrs)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Optimizer.Report\.new\/1 expects attrs as atom or string keyed pairs/,
                 fn ->
                   Imp.Optimizer.Report.new([{123, "bad"}])
                 end
  end

  test "optimizer report restoration rejects non-canonical wire tags" do
    assert_raise ArgumentError, ~r/unsupported Imp JSON wire tag/, fn ->
      Imp.Optimizer.Report.decode_term(%{
        "__imp_type__" => "unknown",
        "items" => [1, 2]
      })
    end
  end

  test "labeled few-shot reports trainset enumeration failures" do
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, :not_an_enumerable_trainset)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :labeled_few_shot
    assert report.candidate_count == 0
    assert report.candidates == []
    assert [%{stage: :trainset, reason: reason}] = report.errors
    assert String.contains?(reason, "Enumerable")
    assert compiled.demos == []
  end

  test "labeled few-shot preserves existing demos when trainset enumeration fails" do
    {train, _dev} = sets()
    [existing_demo] = train

    program =
      "question -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.Predict.Predict.with_demos([existing_demo])

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, :not_an_enumerable_trainset)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert compiled.demos == [existing_demo]
    assert report.metadata.status == :trainset_error
    assert report.metadata.selected_count == 0
    assert [%{stage: :trainset, reason: reason}] = report.errors
    assert String.contains?(reason, "Enumerable")
  end

  test "random search retains DSPy's three baselines when randomized trials are zero" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.RandomSearch.new(candidates: 0, demos_per_candidate: 1)
      |> Imp.Optimizer.RandomSearch.compile(program, train, dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.best_score == 100.0
    assert report.candidate_count == 3
    assert report.errors == []
    assert report.metadata.candidate_seeds == [-3, -2, -1]
    assert Enum.sort(Enum.map(report.candidates, & &1.seed)) == [-3, -2, -1]
  end

  test "optimizer constructors reject invalid option containers at the boundary" do
    metric = Imp.Metrics.exact_match(:answer)

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.LabeledFewShot\.new\/1: expected keyword options/,
                 fn ->
                   Imp.Optimizer.LabeledFewShot.new(%{k: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(metric, %{candidates: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFewShot\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.BootstrapFewShot.new(metric, %{max_bootstrapped_demos: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.LabeledFewShot\.new\/1: invalid value for :k option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.LabeledFewShot.new(k: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2: invalid value for :candidates option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(metric, candidates: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2: invalid value for :demos_per_candidate option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(metric, demos_per_candidate: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFewShot\.new\/2: invalid value for :max_bootstrapped_demos option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.BootstrapFewShot.new(metric, max_bootstrapped_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.KNNFewShot\.new\/3: expected keyword options/,
                 fn ->
                   Imp.Optimizer.KNNFewShot.new(1, [], %{field: :question})
                 end
  end

  test "search optimizer constructors reject invalid metric callbacks at the boundary" do
    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(fn _example -> true end)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFewShot\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Optimizer.BootstrapFewShot.new(fn _example -> true end)
                 end
  end

  test "random search rejects a non-enumerable valset" do
    {train, _dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    assert_raise Protocol.UndefinedError, fn ->
      metric
      |> Imp.Optimizer.RandomSearch.new(candidates: 2, demos_per_candidate: 1)
      |> Imp.Optimizer.RandomSearch.compile(program, train, :not_an_enumerable_devset)
    end
  end

  test "bootstrap few-shot reports selected and rejected train examples" do
    {train, _dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, train)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :bootstrap_few_shot
    assert report.best_score == 0.0
    assert report.metadata.selected_count == 0
    assert report.metadata.trainset_size == 1
    assert [%{passed?: false, selected?: false} = candidate] = report.candidates
    assert candidate.score == 0.0
    assert report.errors == []
    assert compiled.demos == train
  end

  test "bootstrap few-shot captures metric failures as optimizer diagnostics" do
    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm())
    metric = fn _example, _prediction -> raise "metric exploded" end

    compiled =
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, train)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :bootstrap_few_shot
    assert report.metadata.selected_count == 0
    assert [%{stage: :metric, reason: "metric exploded"}] = report.errors

    assert [%{passed?: false, selected?: false, feedback: {:metric_error, "metric exploded"}}] =
             report.candidates
  end

  test "bootstrap few-shot rejects a non-enumerable trainset" do
    {train, _dev} = sets()
    [existing_demo] = train

    program =
      "question -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.Predict.Predict.with_demos([existing_demo])

    assert_raise Protocol.UndefinedError, fn ->
      Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(program, :not_an_enumerable_trainset)
    end
  end

  test "instruction search attaches candidate score report" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown.",
        "Always answer Paris."
      ])

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :instruction_search
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction == "Always answer Paris."))
  end

  test "instruction search evaluates changed programs through callback wrappers" do
    {_train, dev} = sets()

    metric = fn _example_or_inputs, prediction ->
      Imp.Prediction.get(prediction, :answer) == "Paris"
    end

    program =
      "question -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.best_of_n(metric, n: 1)

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Always answer Paris."
      ])

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Always answer Paris."

    assert compiled.program.signature.instructions == "Always answer Paris."
    assert Imp.Optimizer.Report.fetch(compiled).best_score == 1.0
  end

  test "instruction search keeps the baseline when candidates regress" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)

    program =
      "question -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.Optimizer.InstructionSearch.put_instruction("Always answer Paris.")

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown."
      ])

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.best_score == 1.0
    assert report.metadata.baseline_score == 1.0
    assert Enum.any?(report.candidates, &(&1.baseline and &1.score == 1.0))

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Always answer Paris."
  end

  test "instruction search reports all failed evaluations without crashing" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], :not_an_enumerable_devset, [
        "Always answer Paris."
      ])

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :instruction_search
    assert report.best_score == nil
    assert report.candidates == []
    assert report.metadata.status == :all_candidates_failed

    assert Enum.map(report.errors, & &1.instruction) == [
             "Always answer Paris.",
             "Given the fields `question`, produce the fields `answer`."
           ]

    assert Enum.all?(report.errors, &String.contains?(&1.error, "Enumerable"))
  end

  test "instruction search does not hide malformed demo payloads" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    assert_raise ArgumentError,
                 ~r/Imp.Predict.Predict.with_demos\/2 expects demos as Imp.Example structs/,
                 fn ->
                   Imp.Optimizer.InstructionSearch.compile(
                     program,
                     metric,
                     [],
                     dev,
                     ["Always answer Paris."],
                     demos: [:not_a_demo]
                   )
                 end
  end

  test "better together reports unknown strategy keys without crashing" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{p: Imp.Optimizer.LabeledFewShot.new(k: 1)})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: "missing")

    assert {:ok, prediction} = Imp.Predict.Predict.call(compiled, %{question: "Capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "unknown"

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :better_together
    assert report.candidate_count == 1

    assert [%{key: "missing", status: :error, error: {:unknown_optimizer, "missing"}}] =
             report.candidates

    assert [%{key: "missing", error: {:unknown_optimizer, "missing"}}] = report.errors
  end

  test "better together rejects malformed strategy shapes at the boundary" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    better =
      Imp.Optimizer.BetterTogether.new(metric, %{p: Imp.Optimizer.LabeledFewShot.new(k: 1)})

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   Imp.Optimizer.BetterTogether.compile(better, program, train, dev, strategy: "")
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   Imp.Optimizer.BetterTogether.compile(better, program, train, dev, strategy: [])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   Imp.Optimizer.BetterTogether.compile(better, program, train, dev,
                     strategy: %{p: true}
                   )
                 end
  end

  test "better together reports invalid optimizer values without crashing" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{bad: :not_an_optimizer})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: :bad)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :better_together

    assert [%{key: :bad, status: :error, error: {:not_an_optimizer, :not_an_optimizer}}] =
             report.candidates

    assert [%{key: :bad, error: {:not_an_optimizer, :not_an_optimizer}}] = report.errors
  end

  test "better together reports optimizer error tuples instead of treating them as compiled programs" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{bad: %ErrorOptimizer{}})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: :bad)

    assert {:ok, prediction} = Imp.Predict.Predict.call(compiled, %{question: "Capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "unknown"

    report = Imp.Optimizer.Report.fetch(compiled)

    assert [%{key: :bad, status: :error, error: :optimizer_declined}] = report.candidates
    assert [%{key: :bad, error: :optimizer_declined}] = report.errors
  end

  test "better together rejects unloaded optimizer modules through the canonical contract" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())
    unloaded = %{__struct__: :"Elixir.MissingOptimizer"}

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{missing: unloaded})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: :missing)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert [
             %{
               key: :missing,
               status: :error,
               error: {:not_an_optimizer, :"Elixir.MissingOptimizer"}
             }
           ] = report.candidates

    assert [%{key: :missing, error: {:not_an_optimizer, :"Elixir.MissingOptimizer"}}] =
             report.errors
  end

  test "instruction proposer accepts LM-generated scored candidates" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:proposer_messages, messages})
          ~s(["Always answer Paris.", "Mention evidence."])
        end
      ]
    }

    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm)

    assert ["Always answer Paris.", "Mention evidence."] =
             Imp.Optimizer.InstructionSearch.candidate_instructions(program, train,
               lm: lm,
               scores: [%{score: 1.0}]
             )

    assert_received {:proposer_messages, messages}
    assert Enum.map_join(messages, "\n", & &1.content) =~ "scored_examples"
  end

  test "instruction proposer includes signatures from composed program wrappers" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:wrapped_proposer_messages, messages})
          ~s(["Double the number using context."])
        end
      ]
    }

    {train, _dev} = sets()

    program =
      "x, context -> doubled"
      |> Imp.program_of_thought(lm: lm, output_field: :doubled)
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "double x"}]), query_field: :x, k: 1)

    assert ["Double the number using context."] =
             Imp.Optimizer.InstructionProposer.propose(program, train, lm: lm, count: 1)

    assert_received {:wrapped_proposer_messages, messages}
    [%{role: :system}, %{role: :user, content: payload}] = messages
    decoded = Jason.decode!(payload)

    assert get_in(decoded, ["program", "signature"]) == "x, context -> doubled"

    assert get_in(decoded, ["program", "lm_signature"]) ==
             "x, context -> program, tool, arguments"

    assert decoded["current_instruction"] ==
             "Given the fields `x`, `context`, produce the fields `doubled`."
  end

  test "instruction proposer falls back for malformed training rows" do
    program = Imp.predict("question -> answer", lm: lm())

    candidates =
      Imp.Optimizer.InstructionProposer.propose(program, [:not_an_example],
        extra_instructions: ["Use the safe fallback."]
      )

    assert Enum.any?(candidates, &String.contains?(&1, "Given the fields"))
    assert "Use the safe fallback." in candidates
  end

  test "instruction proposer falls back when proposer LM crashes" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> raise "proposal provider offline" end]
    }

    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm())

    candidates =
      Imp.Optimizer.InstructionProposer.propose(program, train,
        lm: lm,
        scores: :not_enumerable_scores
      )

    assert Enum.any?(candidates, &String.contains?(&1, "Given the fields"))
    assert Enum.any?(candidates, &String.contains?(&1, "Return only fields requested"))
  end
end
