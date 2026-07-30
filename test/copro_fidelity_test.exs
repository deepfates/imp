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

  defmodule SafetyLM do
    defstruct [:error]

    def generate(%__MODULE__{error: error}, _messages, _opts), do: {:error, error}
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

  defp proposal_lm do
    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        Jason.encode!(%{
          "proposed_instruction" => "Candidate instruction.",
          "proposed_prefix_for_output_field" => "Answer:"
        })
      end
    )
  end

  test "proposal and evaluation preserve operational safety guards" do
    proposal_safety =
      Imp.OperationalSafetyError.exception(
        kind: :route,
        reason: :provider_drift,
        message: "COPRO proposal route guard"
      )

    assert_raise Imp.OperationalSafetyError, "COPRO proposal route guard", fn ->
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: %SafetyLM{error: proposal_safety},
        breadth: 2,
        depth: 1
      )
      |> COPRO.compile(constant_program(), trainset(), [])
    end

    evaluation_safety =
      Imp.OperationalSafetyError.exception(
        kind: :cost,
        reason: :reservation_exhausted,
        message: "COPRO evaluation cost guard"
      )

    guarded_program =
      Imp.predict("question -> answer", lm: %SafetyLM{error: evaluation_safety})

    assert_raise Imp.OperationalSafetyError, "COPRO evaluation cost guard", fn ->
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposal_lm(),
        breadth: 2,
        depth: 1
      )
      |> COPRO.compile(guarded_program, trainset(), [])
    end
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

  test "required proposal formatting reaches the LM as an exact batch schema" do
    owner = self()

    proposer =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          send(owner, {:proposal_response_format, opts[:response_format]})

          Jason.encode!([
            %{
              "proposed_instruction" => "Answer Paris.",
              "proposed_prefix_for_output_field" => "Answer:"
            }
          ])
        end
      )

    compiled =
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 2,
        depth: 1,
        proposal_response_format: :required
      )
      |> COPRO.compile(constant_program(), trainset(), [])

    assert_received {:proposal_response_format,
                     %{
                       type: "json_schema",
                       json_schema: %{
                         strict: true,
                         schema: %{
                           "type" => "array",
                           "minItems" => 1,
                           "maxItems" => 1,
                           "items" => %{
                             "additionalProperties" => false,
                             "required" => [
                               "proposed_instruction",
                               "proposed_prefix_for_output_field"
                             ]
                           }
                         }
                       }
                     }}

    assert Report.fetch(compiled).metadata.proposal_response_format == :required
  end

  test "initial proposal carries pinned instruction-improvement semantics" do
    owner = self()

    proposer =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:initial_proposal_messages, messages})

          Jason.encode!([
            %{
              "proposed_instruction" => "Answer the location question with one city name.",
              "proposed_prefix_for_output_field" => "Answer:"
            }
          ])
        end
      )

    COPRO.new(Imp.Metrics.exact_match(:answer),
      proposer_lm: proposer,
      breadth: 2,
      depth: 1
    )
    |> COPRO.compile(constant_program(), trainset(), [])

    assert_received {:initial_proposal_messages, [%{role: :system, content: system}, user]}
    assert system =~ "instruction optimizer"
    assert system =~ "improved task instruction"
    assert system =~ "perform the supplied signature well"
    assert system =~ "Do not be afraid to be creative"

    payload = user.content |> Jason.decode!()

    assert payload["basic_instruction"] ==
             "Given the fields `question`, produce the fields `answer`."

    assert payload["attempted_instructions"] == []
    refute user.content =~ "Paris"
  end

  test "later proposal explains ordered score history and asks for a better instruction" do
    owner = self()

    proposer =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(owner, {:proposal_stage, messages, payload})

          for index <- 1..payload["requested_candidate_count"] do
            %{
              "proposed_instruction" => "Candidate #{payload["candidate_index"]}-#{index}",
              "proposed_prefix_for_output_field" => "Answer:"
            }
          end
          |> Jason.encode!()
        end
      )

    COPRO.new(Imp.Metrics.exact_match(:answer),
      proposer_lm: proposer,
      breadth: 2,
      depth: 2
    )
    |> COPRO.compile(constant_program(), trainset(), [])

    assert_received {:proposal_stage, [%{content: initial_system}, _user], initial_payload}
    assert initial_payload["attempted_instructions"] == []
    assert initial_system =~ "improved task instruction"

    assert_received {:proposal_stage, [%{content: history_system}, _user], history_payload}
    assert history_system =~ "attempts are ordered from lower to higher score"
    assert history_system =~ "should perform even better"
    assert history_payload["attempted_instructions"] != []

    assert Enum.any?(history_payload["attempted_instructions"], fn line ->
             String.starts_with?(line, "Resulting Score #")
           end)
  end

  test "required proposal formatting rejects extra fields before task evaluation" do
    owner = self()

    proposer =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Jason.encode!([
            %{
              "proposed_instruction" => "Answer Paris.",
              "proposed_prefix_for_output_field" => "Answer:",
              "explanation" => "This must not cross the executable boundary."
            }
          ])
        end
      )

    program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn _messages, _opts ->
              send(owner, :task_called)
              %{answer: "Paris"}
            end
          )
      )

    assert_raise RuntimeError, ~r/returned no instruction\/prefix candidate/, fn ->
      COPRO.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        breadth: 2,
        depth: 1,
        proposal_response_format: :required
      )
      |> COPRO.compile(program, trainset(), [])
    end

    refute_received :task_called
  end

  test "decodes a JSON candidate inside a markdown fence instead of optimizing the delimiter" do
    proposer =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          """
          Here is the requested candidate:
          ```json
          {"proposed_instruction":"Answer Paris.","proposed_prefix_for_output_field":"Answer:"}
          ```
          """
        end
      )

    compiled =
      COPRO.new(Imp.Metrics.exact_match(:answer), proposer_lm: proposer, breadth: 2, depth: 1)
      |> COPRO.compile(constant_program(), trainset(), [])

    report = Report.fetch(compiled)
    assert Enum.any?(report.candidates, &(&1.instruction == "Answer Paris."))
    refute Enum.any?(report.candidates, &(&1.instruction in ["```", "```json"]))
  end

  test "rejects an invalid fenced proposal before task evaluation" do
    owner = self()

    proposer =
      Imp.LM.Static.new(handler: fn _messages, _opts -> "```json\nnot json\n```" end)

    program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn _messages, _opts ->
              send(owner, :task_called)
              %{answer: "Paris"}
            end
          )
      )

    assert_raise RuntimeError, ~r/returned no instruction\/prefix candidate/, fn ->
      COPRO.new(Imp.Metrics.exact_match(:answer), proposer_lm: proposer, breadth: 2, depth: 1)
      |> COPRO.compile(program, trainset(), [])
    end

    refute_received :task_called
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
        proposer_lm: proposal_lm(),
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
