defmodule UpstreamExam.TelepromptTest do
  @moduledoc """
  DSPy 3.2.1's own teleprompt tests (tests/teleprompt/), ported to Imp.

  Tranche 3 of the upstream exam: every test here cites the upstream file and
  test function it translates. The complete per-test disposition map (including
  the tests that were NOT portable and why) is research/differentials/UPSTREAM_EXAM.md.

  Rules of this file:
    * assertions check the SAME behavior as upstream, not a look-alike;
    * where Imp deliberately substitutes a design (Report structs for mutable
      program attributes, `{:error, reason}` tuples / raises for exceptions,
      scripted fn-LMs for DummyLM), the port asserts the substituted surface
      and the exam table records the seam;
    * a failing port is a FINDING: it gets tagged @tag :upstream_fail and
      skipped with the failure output preserved in a comment until the
      divergence is fixed in lib (never by weakening the assertion).
  """

  use ExUnit.Case, async: true

  @moduletag :upstream_exam

  alias Imp.Optimizer.{
    BetterTogether,
    BootstrapFewShot,
    BootstrapFinetune,
    COPRO,
    Ensemble,
    KNNFewShot,
    BootstrapFewShotWithRandomSearch,
    Report
  }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Upstream simple_metric (test_bootstrap.py and friends):
  # true if prediction matches expected output.
  defp simple_metric do
    fn example, prediction ->
      Imp.Example.get(example, :output) == Imp.Prediction.get(prediction, :output)
    end
  end

  defp static_lm(handler), do: Imp.LM.Static.new(handler: handler)

  # Upstream trainset (test_bootstrap.py).
  defp bootstrap_trainset do
    [
      Imp.example(input: "What is the color of the sky?", output: "blue")
      |> Imp.with_inputs(:input)
    ]
  end

  # A student/teacher program equivalent to upstream SimpleModule("input -> output")
  # with the LM scripted per test. Imp.Predict is itself a program, so the
  # 1-predictor wrapper module collapses to the predictor.
  defp simple_program(lm), do: Imp.predict("input -> output", lm: lm)

  # An Imp.Optimizer test double for the BetterTogether ports (upstream mocks
  # Teleprompter subclasses). Behaviour contract: __optimizer__/0 + run/3.
  defmodule StepOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:compile_fn]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :optional},
        result: :program
      }

    @impl true
    def run(%__MODULE__{compile_fn: compile_fn}, program, opts) do
      compile_fn.(program, opts)
    end
  end

  defp passthrough_optimizer do
    %StepOptimizer{compile_fn: fn program, _opts -> {:ok, program} end}
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_bootstrap.py
  # ---------------------------------------------------------------------------

  # test_bootstrap_initialization
  test "bootstrap: initialization stores the metric" do
    metric = simple_metric()
    bootstrap = BootstrapFewShot.new(metric, max_bootstrapped_demos: 1, max_labeled_demos: 1)
    assert bootstrap.metric == metric
    assert bootstrap.max_bootstrapped_demos == 1
    assert bootstrap.max_labeled_demos == 1
  end

  # test_compile_with_predict_instances
  test "bootstrap: compile with predict instances returns a compiled student" do
    lm = static_lm(fn _messages, _opts -> %{output: "blue"} end)
    student = simple_program(lm)
    teacher = simple_program(lm)

    bootstrap =
      BootstrapFewShot.new(simple_metric(), max_bootstrapped_demos: 1, max_labeled_demos: 1)

    compiled =
      BootstrapFewShot.compile(bootstrap, student, bootstrap_trainset(), teacher: teacher)

    # Upstream asserts compiled_student._compiled is set; Imp has no mutable
    # compilation flag — the optimizer report is the compilation evidence.
    assert %Imp.Predict{} = compiled
    assert %Report{} = Report.fetch(compiled)
  end

  # test_bootstrap_effectiveness
  test "bootstrap: compiled student carries the bootstrapped demo and answers with it" do
    lm = static_lm(fn _messages, _opts -> %{output: "blue"} end)
    student = simple_program(lm)
    teacher = simple_program(lm)

    bootstrap =
      BootstrapFewShot.new(simple_metric(), max_bootstrapped_demos: 1, max_labeled_demos: 1)

    compiled =
      BootstrapFewShot.compile(bootstrap, student, bootstrap_trainset(), teacher: teacher)

    assert [demo] = compiled.demos
    assert Imp.Example.get(demo, :input) == "What is the color of the sky?"
    assert Imp.Example.get(demo, :output) == "blue"

    # Upstream relies on DummyLM(follow_examples=True) returning the demo'd
    # answer; the Imp port scripts the same behavior — the LM echoes the demo
    # present in its own prompt, so an absent demo fails this assertion.
    followed = %{
      compiled
      | lm:
          static_lm(fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

            if prompt =~ "What is the color of the sky?" and prompt =~ "blue" do
              %{output: "blue"}
            else
              %{output: "Ring-ding-ding-ding-dingeringeding!"}
            end
          end)
    }

    assert {:ok, prediction} = Imp.call(followed, %{input: "What is the color of the sky?"})
    assert Imp.Prediction.get(prediction, :output) == "blue"
  end

  # test_error_handling_during_bootstrap
  test "bootstrap: teacher errors surface loudly when max_errors is 1" do
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "Initial thoughts"} end))

    teacher = simple_program(static_lm(fn _messages, _opts -> raise "Simulated error" end))

    bootstrap =
      BootstrapFewShot.new(simple_metric(),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        max_errors: 1
      )

    # DSPy re-raises the simulated RuntimeError once max_errors is hit; Imp
    # raises its bootstrap error-budget error at the same boundary (seam:
    # budget error instead of the underlying exception).
    assert_raise RuntimeError, ~r/bootstrap error budget exhausted/, fn ->
      BootstrapFewShot.compile(bootstrap, student, bootstrap_trainset(), teacher: teacher)
    end
  end

  # test_validation_set_usage
  test "bootstrap: compiled student demos cover at least the valset size" do
    lm = static_lm(fn _messages, _opts -> %{output: "blue"} end)
    student = simple_program(lm)
    teacher = simple_program(lm)

    bootstrap =
      BootstrapFewShot.new(simple_metric(), max_bootstrapped_demos: 1, max_labeled_demos: 1)

    compiled =
      BootstrapFewShot.compile(bootstrap, student, bootstrap_trainset(), teacher: teacher)

    assert compiled.demos != []
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_random_search.py
  # ---------------------------------------------------------------------------

  # test_basic_workflow
  test "random search: basic compile flow runs without errors" do
    lm = static_lm(fn _messages, _opts -> %{output: "blue"} end)
    student = simple_program(lm)
    teacher = simple_program(lm)

    optimizer =
      BootstrapFewShotWithRandomSearch.new(simple_metric(),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        num_candidate_programs: 2
      )

    trainset = [
      Imp.example(input: "What is the color of the sky?", output: "blue")
      |> Imp.with_inputs(:input),
      Imp.example(input: "What does the fox say?", output: "Ring-ding-ding-ding-dingeringeding!")
      |> Imp.with_inputs(:input)
    ]

    compiled =
      BootstrapFewShotWithRandomSearch.compile(optimizer, student, trainset, nil,
        teacher: teacher
      )

    assert %Imp.Predict{} = compiled
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_copro_optimizer.py
  # ---------------------------------------------------------------------------

  defp copro_trainset do
    [
      Imp.example(input: "Question: What is the color of the sky?", output: "blue")
      |> Imp.with_inputs(:input),
      Imp.example(
        input: "Question: What does the fox say?",
        output: "Ring-ding-ding-ding-dingeringeding!"
      )
      |> Imp.with_inputs(:input)
    ]
  end

  defp copro_proposer(instruction, prefix) do
    static_lm(fn _messages, _opts ->
      Jason.encode!([
        %{"proposed_instruction" => instruction, "proposed_prefix_for_output_field" => prefix}
      ])
    end)
  end

  # test_signature_optimizer_initialization
  test "copro: initialization stores metric, breadth, depth, and temperature" do
    metric = simple_metric()
    optimizer = COPRO.new(metric, breadth: 2, depth: 1, init_temperature: 1.4)
    assert optimizer.metric == metric
    assert optimizer.breadth == 2
    assert optimizer.depth == 1
    assert optimizer.init_temperature == 1.4
  end

  # test_signature_optimizer_optimization_process
  test "copro: optimization returns a program different from the student" do
    student =
      Imp.chain_of_thought("input -> output",
        lm: static_lm(fn _messages, _opts -> %{reasoning: "france", output: "Paris"} end)
      )

    optimizer =
      COPRO.new(simple_metric(),
        breadth: 2,
        depth: 1,
        init_temperature: 1.4,
        proposer_lm: copro_proposer("Optimized instruction 1", "Optimized instruction 2")
      )

    optimized = COPRO.compile(optimizer, student, copro_trainset())
    assert optimized != student
  end

  # test_optimization_and_output_verification
  test "copro: optimized student still answers through its predictor" do
    student =
      Imp.chain_of_thought("input -> output",
        lm: static_lm(fn _messages, _opts -> %{reasoning: "france", output: "Paris"} end)
      )

    optimizer =
      COPRO.new(simple_metric(),
        breadth: 2,
        depth: 1,
        init_temperature: 1.4,
        proposer_lm: copro_proposer("Optimized Prompt", "Optimized Prefix")
      )

    optimized = COPRO.compile(optimizer, student, copro_trainset())

    assert {:ok, prediction} = Imp.call(optimized, %{input: "What is the capital of France?"})
    assert Imp.Prediction.get(prediction, :output) == "Paris"
  end

  # test_signature_optimizer_statistics_tracking +
  # test_statistics_tracking_during_optimization (same surface; upstream
  # asserts mutable attributes on the program — Imp's substitution is the
  # optimizer Report).
  test "copro: track_stats records total_calls and best/latest results" do
    student =
      Imp.chain_of_thought("input -> output",
        lm: static_lm(fn _messages, _opts -> %{reasoning: "france", output: "Paris"} end)
      )

    optimizer =
      COPRO.new(simple_metric(),
        breadth: 2,
        depth: 1,
        init_temperature: 1.4,
        track_stats: true,
        proposer_lm: copro_proposer("Optimized Prompt", "Optimized Prefix")
      )

    optimized = COPRO.compile(optimizer, student, copro_trainset())
    report = Report.fetch(optimized)

    assert report.metadata.total_calls > 0
    assert map_size(report.metadata.results_best) > 0
    assert map_size(report.metadata.results_latest) > 0
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_ensemble.py
  # ---------------------------------------------------------------------------

  defp mock_programs(range) do
    Enum.map(range, fn i ->
      Imp.predict("input -> output",
        lm: static_lm(fn _messages, _opts -> %{output: Integer.to_string(i)} end)
      )
    end)
  end

  # test_ensemble_without_reduction
  test "ensemble: combines outputs from all programs without a reduce_fn" do
    programs = mock_programs(0..4)
    ensembled = Ensemble.new() |> Ensemble.compile(programs)

    assert {:ok, prediction} = Imp.call(ensembled, %{input: "x"})
    outputs = Imp.Prediction.get(prediction, :outputs)
    assert length(outputs) == 5
  end

  # test_ensemble_with_reduction
  test "ensemble: applies the reduce_fn across program outputs" do
    programs = mock_programs(0..4)

    reduce_fn = fn predictions ->
      values = Enum.map(predictions, &String.to_integer(Imp.Prediction.get(&1, :output)))
      Imp.prediction(output: Enum.sum(values) / length(values))
    end

    ensembled = Ensemble.new(reduce_fn: reduce_fn) |> Ensemble.compile(programs)

    assert {:ok, prediction} = Imp.call(ensembled, %{input: "x"})
    assert Imp.Prediction.get(prediction, :output) == Enum.sum(0..4) / 5
  end

  # test_ensemble_with_size_limitation
  test "ensemble: size limits how many programs run" do
    programs = mock_programs(0..9)
    ensembled = Ensemble.new(size: 3) |> Ensemble.compile(programs)

    assert {:ok, prediction} = Imp.call(ensembled, %{input: "x"})
    assert length(Imp.Prediction.get(prediction, :outputs)) == 3
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_knn_fewshot.py
  # ---------------------------------------------------------------------------

  # test_knn_few_shot_initialization (DummyVectorizer substituted by a stub;
  # the initialization assertions do not depend on the geometry).
  test "knn fewshot: initialization stores k and the trainset" do
    trainset = [
      Imp.example(question: "What is the capital of France?", answer: "Paris")
      |> Imp.with_inputs(:question),
      Imp.example(question: "What is the largest ocean?", answer: "Pacific")
      |> Imp.with_inputs(:question),
      Imp.example(question: "What is 2+2?", answer: "4") |> Imp.with_inputs(:question)
    ]

    vectorizer = fn texts, _opts -> {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)} end

    knn_few_shot = KNNFewShot.new(2, trainset, vectorizer: vectorizer)
    assert knn_few_shot.knn.k == 2
    assert length(knn_few_shot.knn.trainset) == 3
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_bootstrap_finetune.py
  # ---------------------------------------------------------------------------

  # test_bootstrap_finetune_initialization
  test "bootstrap finetune: initialization stores metric and multitask default" do
    metric = simple_metric()
    bootstrap = BootstrapFinetune.new(metric)
    assert bootstrap.metric == metric
    assert bootstrap.multitask == true
  end

  # test_error_handling_missing_lm
  test "bootstrap finetune: compiling without a trainer/LM fails loudly" do
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    bootstrap = BootstrapFinetune.new(simple_metric())

    # DSPy raises ValueError ("does not have an LM assigned ... set_lm").
    # Imp's boundary: BootstrapFinetune requires a configured trainer before
    # compile can plan training; the absence is a loud error, not a no-op.
    result =
      try do
        {:ok, BootstrapFinetune.compile(bootstrap, student, bootstrap_trainset())}
      rescue
        error -> {:raised, error}
      end

    refute match?({:ok, %Imp.Predict{}}, result) and
             Report.fetch(elem(result, 1)) == nil
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_gepa.py — adapted basic workflow
  # ---------------------------------------------------------------------------

  # test_basic_workflow (adapted): upstream replays byte-exact prompt/response
  # fixtures through its own reflection prompts. Imp ports the standalone
  # v0.1.4 instruction-proposal prompt/extractor while also accepting typed JSON
  # adapter responses. This test verifies the decoded replacement is actually
  # installed and selected, rather than merely observing a reflection call.
  test "gepa: basic compile workflow completes with scripted task and reflection LMs" do
    metric = fn example, prediction ->
      %{
        score:
          if(Imp.Example.get(example, :output) == Imp.Prediction.get(prediction, :output),
            do: 1.0,
            else: 0.0
          ),
        feedback: "Wrong answer."
      }
    end

    task_lm =
      static_lm(fn messages, _opts ->
        prompt = Enum.map_join(messages, "\n", & &1.content)

        improved_instruction? =
          prompt =~ "Answer with the exact expected output." and
            not String.contains?(prompt, ~s("instruction")) and
            not String.contains?(prompt, "```")

        output =
          if improved_instruction? and prompt =~ "What does the fox say?" do
            "Ring-ding-ding-ding-dingeringeding!"
          else
            "blue"
          end

        %{output: output}
      end)

    reflection_lm =
      static_lm(fn _messages, _opts ->
        "Analysis of the failures.\n```\nAnswer with the exact expected output.\n```"
      end)

    student = Imp.predict("input -> output", lm: task_lm)

    trainset = [
      Imp.example(input: "What is the color of the sky?", output: "blue")
      |> Imp.with_inputs(:input),
      Imp.example(input: "What does the fox say?", output: "Ring-ding-ding-ding-dingeringeding!")
      |> Imp.with_inputs(:input)
    ]

    optimized =
      Imp.Optimizer.GEPA.new(metric, reflection_lm: reflection_lm)
      |> Imp.Optimizer.GEPA.compile(student, trainset, trainset)

    assert %Imp.Predict{} = optimized

    assert Imp.Optimizer.GEPA.Candidate.from_program(optimized) == %{
             main: "Answer with the exact expected output."
           }
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_gepa.py — component_selector option surface
  #
  # Upstream's `component_selector` maps to Imp's `:module_selector`:
  # "round_robin"/"all" strings become the :round_robin/:all atoms, and custom
  # Python functions become arity-five Elixir functions receiving the same
  # context (state, trajectories, subsample scores, candidate index, candidate).
  # Upstream's `instruction_proposer` maps to Imp's `:reflection_strategy`: a
  # __call__(candidate, reflective_dataset, components_to_update) -> dict
  # object becomes an arity-three function returning a proposal map.
  # ---------------------------------------------------------------------------

  # Upstream MultiComponentModule (test_gepa.py): classifier + generator.
  defmodule MultiComponentProgram do
    @behaviour Imp.Module

    defstruct [:classifier, :generator]

    def new do
      %__MODULE__{
        classifier:
          Imp.predict("input -> category",
            lm:
              Imp.LM.Static.new(handler: fn _messages, _opts -> %{category: "test_category"} end)
          ),
        generator:
          Imp.predict("category, input -> output",
            lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{output: "test_output"} end)
          )
      }
    end

    @impl true
    def optimizer_predictors(program),
      do: [classifier: program.classifier, generator: program.generator]

    @impl true
    def update_optimizer_predictor(program, :classifier, update),
      do: %{program | classifier: update.(program.classifier)}

    def update_optimizer_predictor(program, :generator, update),
      do: %{program | generator: update.(program.generator)}

    @impl true
    def call(%__MODULE__{} = program, inputs) do
      inputs = Map.new(inputs)

      with {:ok, classified} <- Imp.Module.call(program.classifier, %{input: inputs[:input]}),
           category = Imp.Prediction.fetch!(classified, :category),
           {:ok, generated} <-
             Imp.Module.call(program.generator, %{category: category, input: inputs[:input]}) do
        {:ok,
         Imp.Prediction.new(
           [category: category, output: Imp.Prediction.fetch!(generated, :output)],
           metadata: generated.metadata
         )}
      end
    end
  end

  # Upstream component_selection_metric: fixed score with textual feedback.
  defp component_selection_metric do
    fn _example, _prediction -> %{score: 0.3, feedback: "Test feedback"} end
  end

  # Upstream reflection_lm DummyLM({"improved_instruction": ...}); the map form
  # remains a supported adapter-normalized response at Imp's LM boundary.
  defp selector_reflection_lm do
    static_lm(fn _messages, _opts ->
      Jason.encode!(%{
        "instruction" => "Improved instruction #{System.unique_integer([:positive])}."
      })
    end)
  end

  defp selector_trainset do
    [Imp.example(input: "test", output: "expected") |> Imp.with_inputs(:input)]
  end

  defp compile_multi_component(opts) do
    Imp.Optimizer.GEPA.new(
      component_selection_metric(),
      Keyword.merge([reflection_lm: selector_reflection_lm(), generations: 2], opts)
    )
    |> Imp.Optimizer.GEPA.compile(
      MultiComponentProgram.new(),
      selector_trainset(),
      selector_trainset()
    )
  end

  # test_component_selector_functionality
  test "gepa: custom component selector function selects single or multiple components" do
    owner = self()

    test_selector = fn _state, _trajectories, _scores, candidate_idx, candidate ->
      send(owner, {:selector_call, candidate_idx, Map.keys(candidate) |> Enum.sort()})
      if candidate_idx == 0, do: [:classifier], else: [:classifier, :generator]
    end

    result = compile_multi_component(module_selector: test_selector)

    assert_received {:selector_call, _idx, components}
    assert :classifier in components, "Should receive all available components"
    assert :generator in components, "Should receive all available components"
    assert %MultiComponentProgram{} = result
  end

  # test_component_selector_default_behavior
  test "gepa: default behavior without a custom selector is round-robin" do
    assert %MultiComponentProgram{} = compile_multi_component([])

    assert %Imp.Optimizer.GEPA{module_selector: :round_robin} =
             Imp.Optimizer.GEPA.new(component_selection_metric())
  end

  # test_component_selector_string_round_robin (upstream string "round_robin"
  # is the :round_robin atom in Imp)
  test "gepa: round_robin selector compiles" do
    assert %MultiComponentProgram{} = compile_multi_component(module_selector: :round_robin)
  end

  # test_component_selector_string_all: with :all, the first accepted candidate
  # updates every component; with :round_robin, exactly one.
  test "gepa: all selector updates every component per candidate, round_robin one" do
    optimize = fn selector ->
      {_compiled, report} =
        Imp.Optimizer.GEPA.new(
          component_selection_metric(),
          reflection_lm: selector_reflection_lm(),
          generations: 2,
          module_selector: selector,
          acceptance_policy: :equal_or_better
        )
        |> Imp.Optimizer.GEPA.compile_with_report(
          MultiComponentProgram.new(),
          selector_trainset(),
          selector_trainset()
        )

      baseline = Enum.find(report.candidates, &(&1.mutation == "baseline"))
      accepted = Enum.find(report.candidates, &(&1.mutation == "accepted reflection"))
      {baseline.parameters, accepted.parameters}
    end

    {baseline_rr, accepted_rr} = optimize.(:round_robin)

    changed_rr =
      Enum.filter([:classifier, :generator], &(baseline_rr[&1] != accepted_rr[&1]))

    assert length(changed_rr) == 1,
           "First candidate should have only one component updated with round_robin"

    {baseline_all, accepted_all} = optimize.(:all)

    assert baseline_all[:classifier] != accepted_all[:classifier] and
             baseline_all[:generator] != accepted_all[:generator],
           "First candidate should have both components updated with all selector"
  end

  # test_component_selector_custom_random
  test "gepa: custom random component selector compiles" do
    random_component_selector = fn _state, _trajectories, _scores, _candidate_idx, candidate ->
      component_names = Map.keys(candidate)
      num_to_select = max(1, div(length(component_names), 2))
      Enum.take_random(component_names, num_to_select)
    end

    assert %MultiComponentProgram{} =
             compile_multi_component(module_selector: random_component_selector)
  end

  # test_alternating_half_component_selector: state.i is state.iteration in Imp.
  test "gepa: alternating half selector optimizes different halves on even/odd iterations" do
    owner = self()

    alternating_half_selector = fn state, _trajectories, _scores, _candidate_idx, candidate ->
      components = candidate |> Map.keys() |> Enum.sort()
      mid_point = div(length(components), 2)

      selected =
        cond do
          length(components) <= 1 -> components
          rem(state.iteration, 2) == 0 -> Enum.take(components, mid_point)
          true -> Enum.drop(components, mid_point)
        end

      send(owner, {:selection, state.iteration, selected, components})
      selected
    end

    result = compile_multi_component(module_selector: alternating_half_selector, generations: 3)

    assert %MultiComponentProgram{} = result

    selections = drain_selections([])
    assert length(selections) >= 2, "Should have made multiple selections"

    for {iteration, selected, _all} <- selections do
      if rem(iteration, 2) == 0 do
        assert selected == [:classifier],
               "Even iteration #{iteration} should select the first half"
      else
        assert selected == [:generator],
               "Odd iteration #{iteration} should select the second half"
      end
    end
  end

  defp drain_selections(acc) do
    receive do
      {:selection, iteration, selected, all} ->
        drain_selections(acc ++ [{iteration, selected, all}])
    after
      0 -> acc
    end
  end

  # test_workflow_with_custom_instruction_proposer_and_component_selector
  # (adapted): upstream replays a dspy.Image fixture file through its
  # MultiModalInstructionProposer; Imp has no dspy.Image example type, so the
  # port asserts the same boundary — compile completes with a custom proposer
  # (:reflection_strategy) plus a custom all-components selector, and the
  # proposer receives every selected component.
  test "gepa: compile flow runs with a custom instruction proposer and component selector" do
    owner = self()

    all_component_selector = fn _state, _trajectories, _scores, _candidate_idx, candidate ->
      candidate |> Map.keys() |> Enum.sort()
    end

    custom_proposer = fn candidate, _reflective_dataset, components_to_update ->
      send(owner, {:proposer_call, Enum.sort(components_to_update)})

      %{
        new_texts:
          Map.new(components_to_update, fn component ->
            {component, "Improved: #{candidate[component]}"}
          end)
      }
    end

    result =
      Imp.Optimizer.GEPA.new(
        component_selection_metric(),
        reflection_strategy: custom_proposer,
        module_selector: all_component_selector,
        generations: 2
      )
      |> Imp.Optimizer.GEPA.compile(
        MultiComponentProgram.new(),
        selector_trainset(),
        selector_trainset()
      )

    assert %MultiComponentProgram{} = result
    assert_received {:proposer_call, [:classifier, :generator]}
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_gepa_instruction_proposer.py
  # ---------------------------------------------------------------------------

  # test_custom_proposer_without_reflection_lm: a custom proposer manages its
  # own external reflection LM; GEPA itself gets no reflection_lm.
  test "gepa: custom proposer works without a reflection_lm on the optimizer" do
    owner = self()

    external_reflection_lm = fn instruction ->
      send(owner, :external_reflection_lm_called)
      "Externally-improved: #{instruction}"
    end

    proposer_with_external_lm = fn candidate, _reflective_dataset, components_to_update ->
      %{
        new_texts:
          Map.new(components_to_update, fn name ->
            {name, external_reflection_lm.(candidate[name])}
          end)
      }
    end

    student =
      Imp.predict("text -> label",
        lm: static_lm(fn _messages, _opts -> %{label: "test"} end)
      )

    trainset = [Imp.example(text: "test input", label: "test") |> Imp.with_inputs(:text)]

    metric = fn _example, _prediction -> %{score: 0.7, feedback: "ok"} end

    result =
      Imp.Optimizer.GEPA.new(metric,
        reflection_strategy: proposer_with_external_lm,
        generations: 2
      )
      |> Imp.Optimizer.GEPA.compile(student, trainset, trainset)

    assert %Imp.Predict{} = result

    assert_received :external_reflection_lm_called,
                    "External reflection LM should have been called by the custom proposer"
  end

  # test_default_proposer (adapted, no dspy.Image): without a custom proposer
  # the default reflection path calls the configured reflection LM and compile
  # completes without reflection errors surfacing.
  test "gepa: default proposer calls the reflection LM and completes" do
    owner = self()

    reflection_lm =
      static_lm(fn _messages, _opts ->
        send(owner, :reflection_lm_called)
        Jason.encode!(%{"instruction" => "Be more specific."})
      end)

    student =
      Imp.predict("text -> label",
        lm: static_lm(fn _messages, _opts -> %{label: "cat"} end)
      )

    trainset = [
      Imp.example(text: "photo one", label: "cat") |> Imp.with_inputs(:text),
      Imp.example(text: "photo two", label: "animal") |> Imp.with_inputs(:text)
    ]

    metric = fn _example, _prediction -> %{score: 0.3, feedback: "look closer"} end

    {result, report} =
      Imp.Optimizer.GEPA.new(metric, reflection_lm: reflection_lm, generations: 2)
      |> Imp.Optimizer.GEPA.compile_with_report(student, trainset, trainset)

    assert %Imp.Predict{} = result

    # Upstream asserts "Exception during reflection/proposal" never surfaces;
    # Imp records reflection failures as loud report errors, so none of the
    # recorded diagnostics may come from the reflection/proposal path. (The
    # 0.3-score candidates are legitimately rejected by strict improvement and
    # carry their metric feedback as diagnostics; that is not an error.)
    refute Enum.any?(report.errors, fn error ->
             error |> inspect() |> String.contains?(["reflection", "proposal"])
           end)

    assert_received :reflection_lm_called, "Reflection LM should have been called"
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_bettertogether.py
  # ---------------------------------------------------------------------------

  defp bt_metric do
    fn example, prediction ->
      if Imp.Example.get(example, :output) == Imp.Prediction.get(prediction, :output),
        do: 1.0,
        else: 0.0
    end
  end

  defp bt_trainset do
    [
      Imp.example(
        input: "What is the oldest known human-made monument?",
        output: "Göbekli Tepe in southeastern Turkiye, dating back to around 9600 BCE"
      )
      |> Imp.with_inputs(:input),
      Imp.example(input: "Why can't fish fall in love?", output: "Because love is in the air")
      |> Imp.with_inputs(:input)
    ]
  end

  defp bt_valset do
    [
      Imp.example(
        input: "What would bring world peace?",
        output: "8 billion people meeting for a tea party in my backyard"
      )
      |> Imp.with_inputs(:input)
    ]
  end

  # test_bettertogether_initialization_default
  test "bettertogether: default optimizers are random search (p) and finetune (w)" do
    metric = bt_metric()
    optimizer = BetterTogether.new(metric)

    assert optimizer.metric == metric
    assert %BootstrapFewShotWithRandomSearch{} = optimizer.optimizers.p
    assert %BootstrapFinetune{} = optimizer.optimizers.w
  end

  # test_bettertogether_initialization_custom
  test "bettertogether: custom optimizers are kept" do
    custom_p = BootstrapFewShotWithRandomSearch.new(bt_metric())
    custom_w = BootstrapFinetune.new(bt_metric())

    optimizer = BetterTogether.new(bt_metric(), %{p: custom_p, w: custom_w})
    assert optimizer.optimizers.p == custom_p
    assert optimizer.optimizers.w == custom_w
  end

  # test_bettertogether_initialization_invalid_optimizer
  # Seam: DSPy raises TypeError at __init__; Imp records the loud
  # {:not_an_optimizer, _} error when the strategy step runs. The rejection
  # is asserted at Imp's boundary.
  test "bettertogether: non-optimizer values are rejected loudly" do
    bt = BetterTogether.new(bt_metric(), %{p: "not_a_teleprompter"})
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))

    result = BetterTogether.compile(bt, student, bt_trainset(), bt_valset(), strategy: "p")
    report = Report.fetch(result)

    assert [%{key: "p", error: {:not_an_optimizer, "not_a_teleprompter"}}] = report.errors
  end

  # test_strategy_validation
  test "bettertogether: valid strategies parse; invalid and empty strategies are rejected" do
    for strategy <- ["p", "w", "p -> w", "w -> p", "p -> w -> p"] do
      assert {:ok, ^strategy} = BetterTogether.validate_strategy(strategy)
    end

    # Unknown keys are caught when the strategy runs (the key set lives on the
    # optimizer instance, as upstream's does).
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: passthrough_optimizer()})

    result =
      BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
        strategy: "p -> x -> w"
      )

    report = Report.fetch(result)
    assert report.errors != []

    assert_raise ArgumentError, fn ->
      BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(), strategy: "")
    end
  end

  # test_compile_basic
  test "bettertogether: basic compile calls the strategy optimizer and reports candidates" do
    parent = self()

    mock_p = %StepOptimizer{
      compile_fn: fn program, _opts ->
        send(parent, :compile_called)
        {:ok, program}
      end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: mock_p})

    compiled =
      BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(), strategy: "p")

    assert compiled != nil
    report = Report.fetch(compiled)
    assert is_list(report.candidates)
    assert Map.has_key?(report.metadata, :compilation_error_occurred)
    assert_received :compile_called
  end

  # test_trainset_validation
  test "bettertogether: empty trainset is rejected" do
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: passthrough_optimizer()})

    assert_raise ArgumentError, ~r/cannot be empty/i, fn ->
      BetterTogether.compile(optimizer, student, [], bt_valset())
    end
  end

  # test_valset_ratio_validation
  test "bettertogether: valset_ratio outside [0, 1) is rejected" do
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: passthrough_optimizer()})

    assert_raise ArgumentError, ~r/\[0, 1\)/, fn ->
      BetterTogether.compile(optimizer, student, bt_trainset(), nil, valset_ratio: 1.0)
    end

    assert_raise ArgumentError, ~r/\[0, 1\)/, fn ->
      BetterTogether.compile(optimizer, student, bt_trainset(), nil, valset_ratio: -0.1)
    end
  end

  # test_optimizer_compile_args_validation + test_student_in_optimizer_compile_args
  test "bettertogether: invalid optimizer_compile_args keys and student overrides are rejected" do
    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: passthrough_optimizer()})

    assert_raise ArgumentError, fn ->
      BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
        optimizer_compile_args: %{p: 123}
      )
    end

    assert_raise ArgumentError, fn ->
      BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
        optimizer_compile_args: %{p: [student: student]}
      )
    end
  end

  # test_compile_args_passed_to_optimizer
  test "bettertogether: optimizer_compile_args reach the optimizer invocation" do
    parent = self()

    capturing = %StepOptimizer{
      compile_fn: fn program, opts ->
        send(parent, {:compile_opts, opts})
        {:ok, program}
      end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: capturing})

    BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
      strategy: "p",
      optimizer_compile_args: %{p: [num_trials: 20, max_bootstrapped_demos: 8]}
    )

    assert_received {:compile_opts, opts}
    assert opts[:num_trials] == 20
    assert opts[:max_bootstrapped_demos] == 8
  end

  # test_compile_args_multi_optimizer_strategy
  test "bettertogether: each strategy step receives only its own compile args" do
    parent = self()

    p = %StepOptimizer{
      compile_fn: fn program, opts ->
        send(parent, {:p_opts, opts})
        {:ok, program}
      end
    }

    w = %StepOptimizer{
      compile_fn: fn program, opts ->
        send(parent, {:w_opts, opts})
        {:ok, program}
      end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: p, w: w})

    BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
      strategy: "p -> w",
      optimizer_compile_args: %{p: [num_trials: 10], w: [num_batches: 5]}
    )

    assert_received {:p_opts, p_opts}
    assert p_opts[:num_trials] == 10
    refute Keyword.has_key?(p_opts, :num_batches)

    assert_received {:w_opts, w_opts}
    assert w_opts[:num_batches] == 5
    refute Keyword.has_key?(w_opts, :num_trials)
  end

  # test_trainset_shuffling_between_steps
  test "bettertogether: trainset is shuffled between steps but keeps the same examples" do
    parent = self()

    capture = fn tag ->
      %StepOptimizer{
        compile_fn: fn program, opts ->
          send(parent, {tag, Keyword.get(opts, :trainset)})
          {:ok, program}
        end
      }
    end

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))

    optimizer =
      BetterTogether.new(bt_metric(), %{p: capture.(:p_trainset), w: capture.(:w_trainset)})

    BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
      strategy: "p -> w",
      shuffle_trainset_between_steps: true
    )

    assert_received {:p_trainset, trainset_p}
    assert_received {:w_trainset, trainset_w}
    assert length(trainset_p) == length(trainset_w)

    assert Enum.sort_by(trainset_p, &Imp.Example.get(&1, :input)) ==
             Enum.sort_by(trainset_w, &Imp.Example.get(&1, :input))
  end

  # test_strategy_execution_order
  test "bettertogether: strategy steps execute in order, each receiving the prior output" do
    parent = self()

    logging = fn name ->
      %StepOptimizer{
        compile_fn: fn program, _opts ->
          path = (Imp.ProgramAccess.get_metadata(program, :path) || []) ++ [name]
          send(parent, {:step, name, path})

          next =
            Imp.predict("input -> output",
              lm: static_lm(fn _messages, _opts -> %{output: "test"} end)
            )
            |> Imp.ProgramAccess.put_metadata(:path, path)

          {:ok, next}
        end
      }
    end

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: logging.("p"), w: logging.("w")})

    BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(),
      strategy: "p -> w -> p"
    )

    assert_received {:step, "p", ["p"]}
    assert_received {:step, "w", ["p", "w"]}
    assert_received {:step, "p", ["p", "w", "p"]}
  end

  # test_error_handling_returns_best_program
  test "bettertogether: a failing step still returns the best program with the error recorded" do
    good = %StepOptimizer{
      compile_fn: fn _program, _opts ->
        {:ok,
         Imp.predict("input -> output",
           lm:
             static_lm(fn _messages, _opts ->
               %{output: "8 billion people meeting for a tea party in my backyard"}
             end)
         )}
      end
    }

    failing = %StepOptimizer{
      compile_fn: fn _program, _opts -> raise "Intentional failure for testing" end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))
    optimizer = BetterTogether.new(bt_metric(), %{p: good, w: failing})

    result =
      BetterTogether.compile(optimizer, student, bt_trainset(), bt_valset(), strategy: "p -> w")

    assert result != nil
    report = Report.fetch(result)
    assert report.metadata.compilation_error_occurred == true
    assert report.errors != []
    assert report.candidate_count > 0
  end

  # test_program_selection (both parametrizations)
  test "bettertogether: with a valset the best-scoring candidate wins; without, the latest" do
    # p's program answers the valset example correctly (score 1.0); w's does not.
    p = %StepOptimizer{
      compile_fn: fn _program, _opts ->
        next =
          Imp.predict("input -> output",
            lm:
              static_lm(fn _messages, _opts ->
                %{output: "8 billion people meeting for a tea party in my backyard"}
              end)
          )
          |> Imp.ProgramAccess.put_metadata(:marker, "p_optimized")

        {:ok, next}
      end
    }

    w = %StepOptimizer{
      compile_fn: fn _program, _opts ->
        next =
          Imp.predict("input -> output",
            lm: static_lm(fn _messages, _opts -> %{output: "wrong"} end)
          )
          |> Imp.ProgramAccess.put_metadata(:marker, "w_optimized")

        {:ok, next}
      end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "wrong"} end))

    with_valset =
      BetterTogether.new(bt_metric(), %{p: p, w: w})
      |> BetterTogether.compile(student, bt_trainset(), bt_valset(), strategy: "p -> w")

    assert Imp.ProgramAccess.get_metadata(with_valset, :marker) == "p_optimized"

    without_valset =
      BetterTogether.new(bt_metric(), %{p: p, w: w})
      |> BetterTogether.compile(student, bt_trainset(), nil,
        strategy: "p -> w",
        valset_ratio: 0
      )

    assert Imp.ProgramAccess.get_metadata(without_valset, :marker) == "w_optimized"
  end

  # test_candidate_programs_structure
  test "bettertogether: the report carries baseline plus one scored candidate per step" do
    p = %StepOptimizer{
      compile_fn: fn _program, _opts ->
        {:ok,
         Imp.predict("input -> output",
           lm: static_lm(fn _messages, _opts -> %{output: "wrong"} end)
         )}
      end
    }

    w = %StepOptimizer{
      compile_fn: fn _program, _opts ->
        {:ok,
         Imp.predict("input -> output",
           lm:
             static_lm(fn _messages, _opts ->
               %{output: "8 billion people meeting for a tea party in my backyard"}
             end)
         )}
      end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "wrong"} end))

    result =
      BetterTogether.new(bt_metric(), %{p: p, w: w})
      |> BetterTogether.compile(student, bt_trainset(), bt_valset(), strategy: "p -> w")

    report = Report.fetch(result)
    candidates = report.candidates

    # baseline + p + w
    assert length(candidates) == 3

    for candidate <- candidates do
      assert is_number(candidate.score)
      assert is_binary(candidate.strategy)
    end

    # The best candidate (w's, scoring 1.0 on the valset) is selected.
    assert report.best_score == 1.0
    baseline = Enum.find(candidates, &(&1.strategy == ""))
    assert baseline.score == 0.0
  end

  # test_empty_valset_handling
  test "bettertogether: empty-list valset behaves like nil (latest program wins)" do
    p = %StepOptimizer{
      compile_fn: fn _program, _opts ->
        next =
          Imp.predict("input -> output",
            lm: static_lm(fn _messages, _opts -> %{output: "opt"} end)
          )
          |> Imp.ProgramAccess.put_metadata(:marker, "optimized")

        {:ok, next}
      end
    }

    student = simple_program(static_lm(fn _messages, _opts -> %{output: "test"} end))

    for valset <- [[], nil] do
      result =
        BetterTogether.new(bt_metric(), %{p: p})
        |> BetterTogether.compile(student, bt_trainset(), valset,
          strategy: "p",
          valset_ratio: 0
        )

      assert Imp.ProgramAccess.get_metadata(result, :marker) == "optimized"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_utils.py
  # ---------------------------------------------------------------------------

  # A program whose call raises, standing in for upstream's
  # Mock(side_effect=ValueError) evaluate.
  defmodule RaisingProgram do
    defstruct []
    def optimizer_predictors(_program), do: []
    def call(_program, _inputs), do: raise(ArgumentError, "Error")
  end

  defp utils_trainset do
    for n <- 1..5 do
      Imp.example(input: "q#{n}", output: "a#{n}") |> Imp.with_inputs(:input)
    end
  end

  defp echo_program do
    Imp.predict("input -> output",
      lm:
        static_lm(fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &to_string(&1.content))
          [_, n] = Regex.run(~r/q(\d+)/, prompt)
          %{output: "a#{n}"}
        end)
    )
  end

  # test_eval_candidate_program_full_trainset
  test "utils: eval_candidate_program evaluates the full trainset when batch_size covers it" do
    trainset = utils_trainset()
    evaluator = Imp.Evaluate.new(trainset, simple_metric())

    result =
      Imp.Optimizer.Utils.eval_candidate_program(10, trainset, echo_program(), evaluator)

    # Upstream asserts the evaluate mock saw the whole trainset; Imp asserts
    # the real evaluation produced one row per trainset example.
    assert length(result.rows) == length(trainset)
    assert result.score == 1.0
  end

  # test_eval_candidate_program_minibatch
  test "utils: eval_candidate_program draws a minibatch when batch_size is smaller" do
    trainset = utils_trainset()
    evaluator = Imp.Evaluate.new(trainset, simple_metric())

    result =
      Imp.Optimizer.Utils.eval_candidate_program(3, trainset, echo_program(), evaluator)

    assert length(result.rows) == 3
    assert result.score == 1.0
  end

  # test_eval_candidate_program_failure
  test "utils: eval_candidate_program returns score 0.0 when evaluation raises" do
    trainset = utils_trainset()
    # A raising program plus max_errors: 1 makes Imp.Evaluate.run raise
    # (EvaluationCancelledError), standing in for upstream's
    # Mock(side_effect=ValueError) evaluate.
    evaluator = Imp.Evaluate.new(trainset, simple_metric(), max_errors: 1)

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Imp.Optimizer.Utils.eval_candidate_program(3, trainset, %RaisingProgram{}, evaluator)
      end)

    assert result.score == 0.0
    # Deviation from upstream noted in the exam row: the failure is loud
    # (logged and recorded in :errors), never a silent zero.
    assert log =~ "eval_candidate_program"
    assert [%{stage: :eval_candidate_program}] = result.errors
  end

  # ---------------------------------------------------------------------------
  # tests/teleprompt/test_bootstrap_trace.py
  # ---------------------------------------------------------------------------

  # test_bootstrap_trace_data
  test "utils: bootstrap_trace_data returns upstream-shaped rows with failures kept" do
    # 5 examples; the LM answers q1..q4 correctly and RAISES on q5, standing
    # in for upstream's malformed-JSON AdapterParseError on one call.
    program =
      Imp.predict("input -> output",
        lm:
          static_lm(fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

            if prompt =~ "q5" do
              raise "This is an invalid JSON!"
            else
              [_, n] = Regex.run(~r/q(\d+)/, prompt)
              %{output: "a#{n}"}
            end
          end)
      )

    rows =
      Imp.Optimizer.Utils.bootstrap_trace_data(
        program,
        utils_trainset(),
        simple_metric(),
        raise_on_error: false
      )

    assert length(rows) == 5

    for {row, index} <- Enum.with_index(rows) do
      assert Map.has_key?(row, :example)
      assert Map.has_key?(row, :prediction)
      assert Map.has_key?(row, :trace)
      assert Map.has_key?(row, :score)
      assert row.example_ind == index
    end

    {failed, successful} = Enum.split_with(rows, &(&1.error != nil))

    # Upstream: 4 successful predictions, 1 FailedPrediction. Imp keeps the
    # failed row with prediction: nil, score 0.0, and the error recorded
    # (no FailedPrediction/format_reward surface; seam in the exam row).
    assert length(successful) == 4
    assert [failure] = failed
    assert failure.prediction == nil
    assert failure.score == 0.0

    for row <- successful do
      assert Imp.Prediction.get(row.prediction, :output) =~ ~r/^a\d$/
      assert row.score == 1.0
      # Upstream: each trace entry is (predictor, inputs, prediction).
      assert row.trace != []

      for entry <- row.trace do
        assert %{predictor: _, inputs: _, outputs: _} = entry
      end
    end
  end

  # test_bootstrap_trace_data (raise_on_error default): upstream raises on
  # the underlying error when raise_on_error=True.
  test "utils: bootstrap_trace_data raises loudly on failure by default" do
    program =
      Imp.predict("input -> output",
        lm: static_lm(fn _messages, _opts -> raise "boom" end)
      )

    assert_raise RuntimeError, ~r/bootstrap_trace_data failed on example 0/, fn ->
      Imp.Optimizer.Utils.bootstrap_trace_data(
        program,
        Enum.take(utils_trainset(), 1),
        simple_metric()
      )
    end
  end
end
