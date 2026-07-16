defmodule Imp.Optimizer.COPROFidelityTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{COPRO, Report}

  defmodule TwoPredictorProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    def call(program, _inputs) do
      first_good = program.first.signature.instructions =~ "Be concise and exact."
      second_good = program.second.signature.instructions =~ "Be concise and exact."

      score =
        cond do
          first_good and second_good -> 0.5
          first_good -> 1.0
          true -> 0.0
        end

      {:ok, Imp.Prediction.new(%{score: score})}
    end
  end

  defp trainset do
    [Imp.example(question: "Where?", answer: "Paris") |> Imp.with_inputs(:question)]
  end

  defp constant_program(answer \\ "Paris") do
    Imp.predict("question -> answer",
      lm: %{
        module: Imp.LM.Static,
        opts: [handler: fn _messages, _opts -> %{answer: answer} end]
      }
    )
  end

  test "stores and compares inert prefix metadata without rendering it" do
    parent = self()

    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:proposal_batch, messages})

          Jason.encode!([
            %{
              "proposed_instruction" => "Use the same instruction.",
              "proposed_prefix_for_output_field" => "Alpha Prefix:"
            },
            %{
              "proposed_instruction" => "Use the same instruction.",
              "proposed_prefix_for_output_field" => "Beta Prefix:"
            }
          ])
        end
      ]
    }

    program =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [
            handler: fn messages, _opts ->
              prompt = Enum.map_join(messages, "\n", & &1.content)
              send(parent, {:task_prompt, prompt})
              %{answer: "Paris"}
            end
          ]
        }
      )

    compiled =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 3,
        depth: 1,
        track_stats: true
      )
      |> COPRO.compile(program, trainset(), [])

    report = Report.fetch(compiled)
    prompts = for _ <- 1..3, do: receive(do: ({:task_prompt, prompt} -> prompt))
    same_instruction_prompts = Enum.filter(prompts, &(&1 =~ "Use the same instruction."))

    assert List.last(compiled.signature.outputs).prefix == "Alpha Prefix:"
    assert report.best_score == 100.0
    assert report.metadata.prefix_behavior == :stored_compared_but_not_rendered
    assert report.metadata.proposal_mode == :language_model
    assert report.metadata.total_calls == 3
    assert report.metadata.results_latest.main.depth == [0]
    assert report.metadata.results_best.main.depth == [0]
    assert report.candidate_count == 3

    assert Enum.all?(report.metadata.rounds, fn round ->
             Enum.all?(round.candidates, &(not Map.has_key?(&1, :program)))
           end)

    assert {:ok, _json} = report |> Report.dump() |> Jason.encode()

    assert Enum.sort(Enum.map(same_instruction_prompts, &String.trim/1))
           |> Enum.uniq()
           |> length() ==
             1

    refute Enum.any?(prompts, &(&1 =~ "Alpha Prefix:"))
    refute Enum.any?(prompts, &(&1 =~ "Beta Prefix:"))

    assert Enum.count(report.candidates, fn candidate ->
             candidate.instruction == "Use the same instruction." and
               candidate.prefix in ["Alpha Prefix:", "Beta Prefix:"]
           end) == 2

    assert_received {:proposal_batch, messages}
    payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
    assert payload["requested_candidate_count"] == 2
    refute_receive {:proposal_batch, _messages}
  end

  test "evaluates duplicate pairs but retains the first equal-score record" do
    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Jason.encode!([
            %{
              "proposed_instruction" => "Duplicate instruction.",
              "proposed_prefix_for_output_field" => "Duplicate:"
            },
            %{
              "proposed_instruction" => "Duplicate instruction.",
              "proposed_prefix_for_output_field" => "Duplicate:"
            }
          ])
        end
      ]
    }

    report =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 3,
        depth: 1
      )
      |> COPRO.compile(constant_program(), trainset(), [])
      |> Report.fetch()

    assert report.metadata.total_calls == 3
    assert report.candidate_count == 2

    assert Enum.count(report.candidates, fn candidate ->
             candidate.instruction == "Duplicate instruction." and
               candidate.prefix == "Duplicate:"
           end) == 1
  end

  test "equal-score reevaluation preserves the first insertion and record depth" do
    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()

          candidates = [
            %{
              "proposed_instruction" => "Repeated instruction.",
              "proposed_prefix_for_output_field" => "Repeated:"
            },
            %{
              "proposed_instruction" => "Other instruction.",
              "proposed_prefix_for_output_field" => "Other:"
            }
          ]

          candidates
          |> Enum.take(payload["requested_candidate_count"])
          |> Jason.encode!()
        end
      ]
    }

    report =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 2,
        depth: 2
      )
      |> COPRO.compile(constant_program(), trainset(), [])
      |> Report.fetch()

    repeated =
      Enum.find(report.candidates, fn candidate ->
        candidate.instruction == "Repeated instruction." and candidate.prefix == "Repeated:"
      end)

    assert repeated.depth == 0
    assert report.metadata.total_calls == 4
  end

  test "scores coordinate candidates on trainset rather than the Imp validation argument" do
    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Jason.encode!(%{
            "proposed_instruction" => "Answer Paris.",
            "proposed_prefix_for_output_field" => "Answer:"
          })
        end
      ]
    }

    mismatched_validation = [
      Imp.example(question: "Elsewhere?", answer: "Berlin") |> Imp.with_inputs(:question)
    ]

    compiled =
      COPRO.new(Imp.Metrics.exact_match(:answer), proposer_lm: proposer, breadth: 2, depth: 1)
      |> COPRO.compile(constant_program(), trainset(), mismatched_validation)

    assert Report.fetch(compiled).best_score == 100.0
    assert Report.fetch(compiled).metadata.evaluation_dataset == :trainset
  end

  test "uses Python's ties-to-even rounding for candidate percentages" do
    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Jason.encode!(%{
            "proposed_instruction" => "Keep answering.",
            "proposed_prefix_for_output_field" => "Answer:"
          })
        end
      ]
    }

    trainset =
      Enum.map(1..32, fn index ->
        answer = if index == 1, do: "Paris", else: "Berlin"
        Imp.example(question: "q#{index}", answer: answer) |> Imp.with_inputs(:question)
      end)

    report =
      COPRO.new(Imp.Metrics.exact_match(:answer), proposer_lm: proposer, breadth: 2, depth: 1)
      |> COPRO.compile(constant_program(), trainset, [])
      |> Report.fetch()

    assert report.best_score == 3.12
  end

  test "fans scalar provider responses out with ordered rollout separation" do
    parent = self()

    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          rollout_id = opts[:rollout_id]
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(parent, {:proposal_call, rollout_id, payload})

          if rollout_id == 1, do: Process.sleep(25)

          Jason.encode!(%{
            "proposed_instruction" => "Proposal #{rollout_id}",
            "proposed_prefix_for_output_field" => "Prefix #{rollout_id}:"
          })
        end
      ]
    }

    report =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 4,
        depth: 1,
        proposal_max_concurrency: 2
      )
      |> COPRO.compile(constant_program(), trainset(), [])
      |> Report.fetch()

    calls =
      for _ <- 1..3 do
        receive do
          {:proposal_call, rollout_id, payload} -> {rollout_id, payload}
        end
      end
      |> Enum.sort_by(&elem(&1, 0))

    assert Enum.map(calls, &elem(&1, 0)) == [0, 1, 2]

    assert Enum.map(calls, fn {_id, payload} -> payload["requested_candidate_count"] end) == [
             3,
             1,
             1
           ]

    assert report.candidates |> Enum.take(3) |> Enum.map(& &1.instruction) == [
             "Proposal 0",
             "Proposal 1",
             "Proposal 2"
           ]

    refute_receive {:proposal_call, _rollout_id, _payload}
  end

  test "preserves 3.2.1's cumulative latest-score statistics across predictors" do
    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()

          Jason.encode!(%{
            "proposed_instruction" => payload["basic_instruction"] <> "\nBe concise and exact.",
            "proposed_prefix_for_output_field" => "Candidate:"
          })
        end
      ]
    }

    first = with_instructions(Imp.predict("question -> hint"), "first base")
    second = with_instructions(Imp.predict("hint -> answer"), "second base")
    program = %TwoPredictorProgram{first: first, second: second}
    metric = fn _example, prediction -> Imp.get(prediction, :score) end

    compiled =
      COPRO.new(metric,
        proposer_lm: proposer,
        breadth: 2,
        depth: 1,
        track_stats: true
      )
      |> COPRO.compile(program, trainset(), [])

    report = Report.fetch(compiled.first)

    assert report.metadata.results_latest.first.average == [50.0]
    assert report.metadata.results_latest.second.average == [62.5]
    assert report.metadata.latest_score_scope == :cumulative_across_predictors_per_depth
  end

  test "aborts candidate evaluation at the eval_kwargs error threshold" do
    proposer = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Jason.encode!(%{
            "proposed_instruction" => "Fail once.",
            "proposed_prefix_for_output_field" => "Answer:"
          })
        end
      ]
    }

    failing =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> raise "task provider failed" end]
        }
      )

    optimizer =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 2,
        depth: 1
      )

    assert_raise RuntimeError, ~r/COPRO evaluation error budget exhausted/, fn ->
      COPRO.compile(optimizer, failing, trainset(), [], max_errors: 1, num_threads: 1)
    end

    assert_raise RuntimeError, ~r/1 errors \(maximum 0\)/, fn ->
      COPRO.compile(optimizer, failing, trainset(), [], max_errors: 0, num_threads: 1)
    end

    report =
      COPRO.compile(optimizer, failing, trainset(), [],
        max_errors: :infinity,
        num_threads: 1
      )
      |> Report.fetch()

    assert report.metadata.max_errors == :infinity
    assert report.metadata.max_errors_source == :explicit
    assert length(report.errors) == 2
  end

  test "nil eval max_errors inherits process settings and explicit eval options win" do
    optimizer =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        breadth: 2,
        depth: 1,
        extra_instructions: ["Candidate instruction."]
      )

    inherited =
      Imp.context([max_errors: 5], fn ->
        COPRO.compile(optimizer, constant_program(), trainset(), [])
      end)
      |> Report.fetch()

    explicit =
      Imp.context([max_errors: 5], fn ->
        COPRO.compile(optimizer, constant_program(), trainset(), [], max_errors: 9)
      end)
      |> Report.fetch()

    assert {inherited.metadata.max_errors, inherited.metadata.max_errors_source} == {5, :settings}
    assert {explicit.metadata.max_errors, explicit.metadata.max_errors_source} == {9, :explicit}
  end

  defp with_instructions(predictor, instructions) do
    Imp.Predict.Predict.with_signature(predictor, %{
      predictor.signature
      | instructions: instructions
    })
  end
end
