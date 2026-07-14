defmodule Imp.Optimizer.Playbook.Campaign do
  @moduledoc false

  alias Imp.BenchmarkTruth.{BudgetedLM, CampaignBudget}
  alias Imp.Optimizer.Playbook, as: PlaybookOptimizer
  alias Imp.Optimizer.Playbook.EquationSearch
  alias Imp.Optimizer.Trajectory
  alias Imp.Playbook
  alias Imp.Playbook.{Delta, Provenance}
  alias Imp.Playbook.Operation.{Add, Revise}

  @model "openai:gpt-4.1-mini-2025-04-14"
  @input_per_million 0.40
  @output_per_million 1.60
  @code_act_max_iters 2
  @evaluation_requests_per_row 3
  @proposal_max_attempts 2
  @implementation_sources [
    "lib/imp/optimizer/playbook.ex",
    "lib/imp/optimizer/playbook/campaign.ex",
    "lib/imp/optimizer/playbook/equation_search.ex",
    "lib/imp/playbook/with_context.ex",
    "lib/imp/program_parameters.ex",
    "lib/mix/tasks/imp.benchmark.playbook.ex"
  ]
  @authority %{
    "dynamic_cheatsheet" => %{
      "paper" => "arXiv:2504.07952",
      "paper_pdf_sha256" => "660680ecc5cdb8f4d921e1284bf95df2dfa9020c5923330e406fff9b93bcfd00",
      "repository" => "https://github.com/suzgunmirac/dynamic-cheatsheet",
      "commit" => "5cfe3c37e8e52b1d858d0f3df46e7f17c50991b9"
    },
    "ace" => %{
      "paper" => "arXiv:2510.04618",
      "paper_pdf_sha256" => "51050ced82df75c143b151262d5af8763916968ca50374bd8ff778f40552b0ad",
      "repository" => "https://github.com/ace-agent/ace",
      "commit" => "bcb7cea0504afad6f55fec4845dd4864c9f9eee7",
      "curator_sha256" => "863aa928b28538ded4b86ed330ce40c6012f6ca215f94618bef0615fb4de281b",
      "reflector_sha256" => "fe5ae8fb006fd16fdef7b8e7ad38dc746195a4bf0a366a82e69c473c9982b811"
    },
    "model_pricing" => %{
      "source" => "https://developers.openai.com/api/docs/models/gpt-4.1-mini",
      "input_usd_per_million" => @input_per_million,
      "output_usd_per_million" => @output_per_million
    }
  }

  @baseline_strategy """
  Complete each equation by replacing every question mark with one arithmetic operator. Keep the given numbers in their original order, use ordinary operator precedence, and return only one completed equation with the stated right-hand value. Work carefully and check that the expression is valid before answering. Do not add numbers, omit numbers, reorder numbers, or introduce parentheses.
  """

  @capacity_reserve String.duplicate(
                      "Reserved bounded parameter capacity for a future validated strategy revision. ",
                      10
                    )

  @doc "Runs one bounded natural equation-balancing playbook campaign."
  def run(config, api_key) when is_map(config) and is_binary(api_key) and api_key != "" do
    config = validate_config!(config)
    dataset = load_dataset!(config)
    splits = split(dataset.rows, config)
    limits = aggregate_limits(config)

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: limits,
        pricing: %{
          "input_per_million" => @input_per_million,
          "output_per_million" => @output_per_million
        },
        default_max_output_tokens: config.max_output_tokens
      )

    handler = CampaignBudget.attach_req_llm(budget)

    try do
      evaluator_lm = budgeted_lm(config.model, api_key, config.max_output_tokens, budget)

      proposer_lm =
        budgeted_lm(config.model, api_key, config.max_proposal_output_tokens, budget)

      baseline = baseline_playbook(dataset)
      registry = saving_registry()
      program = equation_program(evaluator_lm, baseline)

      optimizer =
        PlaybookOptimizer.new(
          proposer: proposer(proposer_lm, budget, config, dataset),
          evaluator: evaluator(budget, config, evaluator_lm, registry),
          reservations: reservations(config),
          budget: usage_limit(limits, config.model),
          min_lift: config.min_lift,
          max_growth_bytes: 0,
          max_growth_ratio: 1.0,
          checkpoint_fn: checkpoint_writer(config.checkpoint)
        )

      case PlaybookOptimizer.compile(
             optimizer,
             program,
             splits.train,
             splits.promotion,
             splits.audit
           ) do
        {:ok, result} ->
          artifact(config, dataset, splits, result, CampaignBudget.snapshot(budget), api_key)

        {:error, reason} ->
          raise ArgumentError, "playbook campaign failed closed: #{inspect(reason)}"
      end
    after
      :telemetry.detach(handler)
      GenServer.stop(budget)
    end
  end

  @doc false
  def validate_equation(input, answer, target_value)
      when is_binary(input) and is_binary(answer) and is_integer(target_value) do
    EquationSearch.validate(input, answer, target_value)
  end

  def validate_equation(_input, _answer, _target), do: {:error, :invalid_equation_types}

  @doc false
  def split(rows, config) do
    ordered = Enum.sort_by(rows, &sha256("#{config.seed}:#{&1["id"]}"))
    {train, remaining} = Enum.split(ordered, config.train_count)
    {promotion, remaining} = Enum.split(remaining, config.promotion_count)
    {audit, _remaining} = Enum.split(remaining, config.audit_count)
    %{train: train, promotion: promotion, audit: audit}
  end

  defp proposer(lm, budget, config, dataset) do
    fn request ->
      before = CampaignBudget.snapshot(budget)
      summary = training_summary(request.rows, request.trajectories)

      signature =
        Imp.signature(
          "current_strategy, training_evidence, proposal_feedback -> strategy",
          """
          Revise the current equation-balancing strategy using only the supplied training evidence. Return one reusable strategy under 550 characters in at most three short sentences. It must not contain any example equation, answer, dataset row ID, or copied number sequence. The strategy MUST literally contain `solve_equation`, `equation`, `observation`, and `finished`: direct the executor to call `solve_equation` with the original `equation`, then evaluate the safe program `observation` with `finished` true. Correct any proposal_feedback. Return strategy text only.
          """
        )

      proposal_program =
        Imp.predict(signature,
          lm: lm,
          adapter: Imp.Adapter.JSON,
          config: [native_json_schema: true]
        )

      inputs = %{
        current_strategy: hd(request.playbook.entries).content,
        training_evidence: summary,
        proposal_feedback: "none"
      }

      result = generate_strategy(proposal_program, inputs, request.rows, @proposal_max_attempts)

      usage = usage_delta(before, CampaignBudget.snapshot(budget), config.model)

      case result do
        {:ok, strategy} ->
          provenance = %Provenance{
            source_ids: Enum.map(request.rows, & &1["source_id"]),
            digests: [dataset.sha256]
          }

          delta =
            Delta.new(
              [
                Revise.new("equation-strategy", strategy,
                  expected_revision: 1,
                  provenance: provenance
                ),
                Revise.new("optimizer-capacity", "Validated strategy capacity released.",
                  expected_revision: 1,
                  provenance: provenance
                )
              ],
              expected_revision: request.playbook.revision,
              parent_hash: request.playbook.hash
            )

          {:ok, delta, usage}

        {:error, reason} ->
          {:error, reason, usage}
      end
    end
  end

  defp generate_strategy(program, inputs, rows, attempts_left) do
    case Imp.call(program, inputs) do
      {:ok, prediction} ->
        strategy = prediction |> Imp.get(:strategy, "") |> Playbook.Entry.normalize()

        case strategy_rejection(strategy, rows) do
          :ok ->
            {:ok, strategy}

          reason when attempts_left > 1 ->
            generate_strategy(
              program,
              Map.put(inputs, :proposal_feedback, inspect(reason)),
              rows,
              attempts_left - 1
            )

          reason ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp strategy_rejection("", _rows), do: :empty_strategy

  defp strategy_rejection(strategy, rows) do
    normalized = String.downcase(strategy)
    required = ~w(solve_equation equation observation finished)
    missing = Enum.reject(required, &String.contains?(normalized, &1))

    cond do
      byte_size(strategy) > 600 ->
        {:strategy_too_large, byte_size(strategy)}

      contains_training_instance?(strategy, rows) ->
        :strategy_copied_training_instance

      missing != [] ->
        {:strategy_missing_protocol_terms, missing}

      true ->
        :ok
    end
  end

  defp evaluator(budget, config, evaluator_lm, registry) do
    fn program, rows, context ->
      program =
        if context.stage in [:baseline_audit, :candidate_audit] do
          program
          |> Imp.Saving.dump(registry: registry)
          |> Imp.Saving.load(registry: registry)
          |> rebind_lm(evaluator_lm)
        else
          program
        end

      before = CampaignBudget.snapshot(budget)
      started = System.monotonic_time(:microsecond)

      result =
        rows
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, trajectories} ->
          call_started = System.monotonic_time(:microsecond)

          case Imp.call(program, %{equation: row["input"]}) do
            {:ok, prediction} ->
              answer = Imp.get(prediction, :answer, "")
              valid = validate_equation(row["input"], answer, row["target_value"])
              score = if valid == :ok, do: 1.0, else: 0.0

              trajectory =
                Trajectory.project(
                  :evaluation,
                  %{
                    index: index,
                    example: %{
                      "id" => row["id"],
                      "source_id" => row["source_id"],
                      "group_id" => row["group_id"]
                    },
                    prediction: %{"answer" => answer},
                    trace: normalize_code_act_trace(prediction),
                    score: score,
                    feedback: %{
                      "valid" => valid == :ok,
                      "reason" => if(valid == :ok, do: nil, else: inspect(valid)),
                      "reference" => row["expected"]
                    },
                    metric_metadata: %{
                      "metric" => "operator_assignment_exact_arithmetic_v1",
                      "stage" => Atom.to_string(context.stage)
                    },
                    error: nil
                  },
                  timing: %Trajectory.Timing{
                    duration_us: System.monotonic_time(:microsecond) - call_started
                  }
                )

              {:cont, {:ok, trajectories ++ [trajectory]}}

            {:error, reason} ->
              case classify_model_failure(reason) do
                {:ok, label, details} ->
                  trajectory =
                    failure_trajectory(
                      row,
                      index,
                      context.stage,
                      label,
                      details,
                      System.monotonic_time(:microsecond) - call_started
                    )

                  {:cont, {:ok, trajectories ++ [trajectory]}}

                :unknown ->
                  {:halt, {:error, {:provider_call_failed, index, reason}}}
              end
          end
        end)

      after_snapshot = CampaignBudget.snapshot(budget)
      usage = usage_delta(before, after_snapshot, config.model)

      case result do
        {:ok, trajectories} ->
          elapsed = System.monotonic_time(:microsecond) - started

          trajectories =
            Enum.map(trajectories, fn trajectory ->
              Trajectory.project(:evaluation, trajectory,
                metadata: Map.put(trajectory.metadata, :stage_elapsed_us, elapsed)
              )
            end)

          {:ok, trajectories, usage}

        {:error, reason} ->
          {:error, reason, usage}
      end
    end
  end

  defp equation_program(lm, playbook) do
    signature =
      Imp.signature(
        "equation -> answer",
        "Replace every ? with exactly one of +, -, *, or /. Keep all numbers in their given order, use standard precedence without parentheses, and return only the completed equation including its right-hand side."
      )

    solver =
      Imp.tool(
        :solve_equation,
        "Exhaustively test operator tuples with exact rational standard-precedence arithmetic and return a verified completed equation",
        &EquationSearch.solve_tool/1,
        schema: %{
          "type" => "object",
          "properties" => %{
            "equation" => %{"type" => "string", "maxLength" => 256},
            "numbers" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "maxItems" => 8
            },
            "target" => %{"type" => "integer"}
          },
          "anyOf" => [
            %{"required" => ["equation"]},
            %{"required" => ["numbers", "target"]}
          ],
          "additionalProperties" => false
        }
      )

    signature
    |> Imp.code_act([solver],
      lm: lm,
      adapter: Imp.Adapter.JSON,
      config: [native_json_schema: true],
      max_iters: @code_act_max_iters,
      tool_policy: [:solve_equation]
    )
    |> Imp.with_playbook(playbook)
  end

  defp budgeted_lm(model, api_key, max_tokens, budget) do
    inner =
      Imp.req_llm(model,
        api_key: api_key,
        temperature: 0,
        max_tokens: max_tokens,
        cache: false
      )

    %BudgetedLM{inner: inner, budget: budget}
  end

  defp rebind_lm(program, lm) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      Imp.ProgramParameters.update_predictor(acc, name, &Imp.Predict.Predict.with_lm(&1, lm))
    end)
  end

  defp baseline_playbook(dataset) do
    root =
      Playbook.new(
        id: "dynamic-cheatsheet-equation-balancer",
        policy:
          Playbook.Policy.new(
            max_entries: 8,
            max_tombstones: 16,
            max_operations: 4,
            max_entry_bytes: 1_024,
            max_playbook_bytes: 8_192
          )
      )

    {:ok, playbook} =
      Playbook.apply_delta(root, [
        Add.new(@baseline_strategy,
          id: "equation-strategy",
          section: "Equation balancing",
          provenance:
            Provenance.new(
              source_ids: ["dynamic-cheatsheet:task-contract"],
              digests: [dataset.sha256]
            )
        ),
        Add.new(@capacity_reserve,
          id: "optimizer-capacity",
          section: "Optimizer capacity",
          status: :inactive,
          provenance:
            Provenance.new(
              source_ids: ["imp:bounded-context-capacity"],
              digests: [dataset.sha256]
            )
        )
      ])

    playbook
  end

  defp training_summary(rows, trajectories) do
    Enum.zip(rows, trajectories)
    |> Enum.map_join("\n", fn {row, trajectory} ->
      answer = get_in(trajectory.prediction, ["answer"])

      Jason.encode!(%{
        "input" => row["input"],
        "model_answer" => answer,
        "reference" => row["expected"],
        "correct" => trajectory.score == 1.0
      })
    end)
  end

  defp contains_training_instance?(strategy, rows) do
    normalized = String.downcase(strategy)

    Enum.any?(rows, fn row ->
      String.contains?(normalized, String.downcase(row["input"])) or
        String.contains?(normalized, String.downcase(row["expected"]))
    end)
  end

  defp usage_delta(before, after_snapshot, model) do
    input =
      get_in(after_snapshot, ["usage", "input_tokens"]) -
        get_in(before, ["usage", "input_tokens"])

    output =
      get_in(after_snapshot, ["usage", "output_tokens"]) -
        get_in(before, ["usage", "output_tokens"])

    requests = after_snapshot["requests"] - before["requests"]
    cost = input / 1_000_000 * @input_per_million + output / 1_000_000 * @output_per_million

    %{
      requests: requests,
      input_tokens: input,
      output_tokens: output,
      cost_usd: cost,
      authority: :derived,
      models: [model]
    }
  end

  defp reservations(config) do
    %{
      training_evaluation: stage_limit(config.train_count, config),
      proposal: proposal_limit(config),
      baseline_promotion: stage_limit(config.promotion_count, config),
      candidate_promotion: stage_limit(config.promotion_count, config),
      baseline_audit: stage_limit(config.audit_count, config),
      candidate_audit: stage_limit(config.audit_count, config)
    }
  end

  defp stage_limit(count, config) do
    requests = count * @evaluation_requests_per_row
    input = requests * config.max_input_tokens_per_call
    output = requests * config.max_output_tokens

    usage_limit(
      %{
        requests: requests,
        input_tokens: input,
        output_tokens: output,
        usd: price(input, output)
      },
      config.model
    )
  end

  defp proposal_limit(config) do
    input = @proposal_max_attempts * config.max_proposal_input_tokens
    output = @proposal_max_attempts * config.max_proposal_output_tokens

    usage_limit(
      %{
        requests: @proposal_max_attempts,
        input_tokens: input,
        output_tokens: output,
        usd: price(input, output)
      },
      config.model
    )
  end

  defp aggregate_limits(config) do
    reservations(config)
    |> Enum.reduce(%{requests: 0, input_tokens: 0, output_tokens: 0, usd: 0.0}, fn {_stage, usage},
                                                                                   acc ->
      %{
        requests: acc.requests + usage.requests,
        input_tokens: acc.input_tokens + usage.input_tokens,
        output_tokens: acc.output_tokens + usage.output_tokens,
        usd: acc.usd + usage.cost_usd
      }
    end)
  end

  defp usage_limit(limits, model) do
    %PlaybookOptimizer.Usage{
      requests: limits.requests,
      input_tokens: limits.input_tokens,
      output_tokens: limits.output_tokens,
      cost_usd: limits.usd,
      authority: :derived,
      models: [model]
    }
  end

  defp price(input, output),
    do: input / 1_000_000 * @input_per_million + output / 1_000_000 * @output_per_million

  defp checkpoint_writer(path) do
    fn checkpoint ->
      atomic_write!(path, Jason.encode!(checkpoint, pretty: true) <> "\n")
      :ok
    end
  end

  defp artifact(config, dataset, splits, result, budget, api_key) do
    baseline_bytes = PlaybookOptimizer.retained_bytes(result.baseline_playbook)
    candidate_bytes = PlaybookOptimizer.retained_bytes(result.candidate_playbook)

    artifact = %{
      "schema_version" => 1,
      "evidence_tier" => "live_source_group_disjoint_natural_playbook_campaign",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "implementation" => implementation_identity(),
      "authorities" => @authority,
      "model" => config.model,
      "dataset" => dataset.provenance,
      "splits" => %{
        "seed" => config.seed,
        "train_ids" => Enum.map(splits.train, & &1["id"]),
        "promotion_ids" => Enum.map(splits.promotion, & &1["id"]),
        "audit_ids" => Enum.map(splits.audit, & &1["id"]),
        "source_group_disjoint" => true
      },
      "outcome" => %{
        "promoted" => result.promoted?,
        "scores" => stringify_keys(result.scores),
        "rejection_reasons" => Enum.map(result.rejection_reasons, &inspect/1),
        "baseline_retained_bytes" => baseline_bytes,
        "candidate_retained_bytes" => candidate_bytes,
        "context_growth_bytes" => candidate_bytes - baseline_bytes,
        "growth_gate_passed" => candidate_bytes <= baseline_bytes,
        "persistence_reloaded_for_audit" => true,
        "heldout_content_and_provenance_gate_passed" => true
      },
      "usage" => dump_usage(result.usage),
      "budget" => budget,
      "playbooks" => %{
        "baseline" => Playbook.dump(result.baseline_playbook),
        "candidate" => Playbook.dump(result.candidate_playbook),
        "selected_hash" => result.program.playbook.hash
      },
      "rows" => dump_rows(result.trajectories),
      "mechanism" => mechanism_evidence(result.trajectories),
      "checkpoint" => %{
        "path" => config.checkpoint,
        "payload_sha256" => result.checkpoint["payload_sha256"]
      },
      "claims" => %{
        "durable_natural_heldout_lift" => result.promoted?,
        "bounded_no_context_growth" => candidate_bytes <= baseline_bytes,
        "dynamic_cheatsheet_exact_parity" => false,
        "ace_exact_parity" => false
      },
      "limitations" => [
        "This is one bounded equation-balancing campaign, not a cross-domain effectiveness claim.",
        "The same pinned model proposes and executes the strategy; the two held-out splits prevent example reuse but do not prove causal mechanism isolation.",
        "Imp adopts the incremental playbook idea while intentionally using typed atomic deltas and held-out promotion rather than reproducing upstream string rewriting."
      ]
    }

    encoded = Jason.encode!(artifact, pretty: true) <> "\n"
    if String.contains?(encoded, api_key), do: raise(ArgumentError, "artifact retained API key")
    atomic_write!(config.out, encoded)
    artifact
  end

  defp dump_rows(trajectories) do
    trajectories
    |> Enum.sort_by(fn {stage, _rows} -> Atom.to_string(stage) end)
    |> Enum.flat_map(fn {stage, rows} ->
      Enum.map(rows, fn row ->
        %{
          "stage" => Atom.to_string(stage),
          "id" => row.example["id"],
          "score" => row.score,
          "answer" => row.prediction["answer"],
          "feedback" => row.feedback,
          "playbook_hash" => List.last(row.named_parameters).value,
          "duration_us" => row.timing.duration_us
        }
      end)
    end)
  end

  defp mechanism_evidence(trajectories) do
    Map.new(trajectories, fn {stage, rows} ->
      tool_calls =
        Enum.count(rows, fn row ->
          Enum.any?(row.trace, &match?(%{tool: :solve_equation}, &1))
        end)

      {Atom.to_string(stage), %{"rows" => length(rows), "solve_equation_calls" => tool_calls}}
    end)
  end

  @doc false
  def classify_model_failure(%{reason: {:error, %Jason.DecodeError{}}, trace: %{raw: raw}}),
    do: {:ok, "adapter_decode_failure", %{"raw_sha256" => sha256(raw)}}

  def classify_model_failure({kind, _details})
      when kind in [:code_act_sandbox_error, :code_act_max_iters, :invalid_program_outputs],
      do: {:ok, Atom.to_string(kind), %{}}

  def classify_model_failure({kind, _details, _trace})
      when kind in [:code_act_sandbox_error, :code_act_max_iters, :code_act_tool_error],
      do: {:ok, Atom.to_string(kind), %{}}

  def classify_model_failure(_reason), do: :unknown

  defp failure_trajectory(row, index, stage, label, details, duration_us) do
    Trajectory.project(
      :evaluation,
      %{
        index: index,
        example: %{
          "id" => row["id"],
          "source_id" => row["source_id"],
          "group_id" => row["group_id"]
        },
        prediction: %{"answer" => ""},
        trace: [],
        score: 0.0,
        feedback:
          Map.merge(
            %{"valid" => false, "reason" => label, "reference" => row["expected"]},
            details
          ),
        metric_metadata: %{
          "metric" => "operator_assignment_exact_arithmetic_v1",
          "stage" => Atom.to_string(stage),
          "scored_failure" => true
        },
        error: nil
      },
      timing: %Trajectory.Timing{duration_us: duration_us}
    )
  end

  defp saving_registry do
    Imp.Saving.Registry.new(solve_equation: &EquationSearch.solve_tool/1)
  end

  @doc false
  def normalize_code_act_trace(%Imp.Prediction{} = prediction) do
    prediction.metadata
    |> Map.get(:code_act_trace, [])
    |> Enum.map(fn
      %{action: :tool, input: %{name: name, arguments: arguments}, output: result} ->
        %{tool: name, arguments: arguments, result: result}

      %{action: action, input: input, output: output} ->
        %{action: action, input: %{value: input}, output: output}
    end)
  end

  defp load_dataset!(config) do
    data_bytes = File.read!(config.data)
    provenance = config.provenance |> File.read!() |> Jason.decode!()
    rows = data_bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    valid =
      sha256(data_bytes) == get_in(provenance, ["materialized", "sha256"]) and
        length(rows) == get_in(provenance, ["materialized", "rows"]) and
        sha256(File.read!(config.source)) == get_in(provenance, ["source", "sha256"]) and
        sha256(File.read!(get_in(provenance, ["builder", "path"]))) ==
          get_in(provenance, ["builder", "sha256"])

    unless valid, do: raise(ArgumentError, "playbook dataset provenance mismatch")

    %{rows: rows, sha256: sha256(data_bytes), provenance: provenance}
  end

  defp validate_config!(config) do
    expected =
      ~w(audit_count checkpoint data max_input_tokens_per_call max_output_tokens max_proposal_input_tokens max_proposal_output_tokens min_lift model out promotion_count provenance seed source train_count)

    unless Enum.sort(Map.keys(config)) == expected,
      do: raise(ArgumentError, "playbook campaign config keys mismatch")

    unless config["model"] == @model,
      do: raise(ArgumentError, "campaign model must remain pinned to #{@model}")

    integer_keys =
      ~w(audit_count max_input_tokens_per_call max_output_tokens max_proposal_input_tokens max_proposal_output_tokens promotion_count seed train_count)

    unless Enum.all?(integer_keys, &(is_integer(config[&1]) and config[&1] > 0)) and
             is_number(config["min_lift"]) and config["min_lift"] >= 0 do
      raise ArgumentError, "invalid playbook campaign bounds"
    end

    %{
      audit_count: config["audit_count"],
      checkpoint: config["checkpoint"],
      data: config["data"],
      max_input_tokens_per_call: config["max_input_tokens_per_call"],
      max_output_tokens: config["max_output_tokens"],
      max_proposal_input_tokens: config["max_proposal_input_tokens"],
      max_proposal_output_tokens: config["max_proposal_output_tokens"],
      min_lift: config["min_lift"],
      model: config["model"],
      out: config["out"],
      promotion_count: config["promotion_count"],
      provenance: config["provenance"],
      seed: config["seed"],
      source: config["source"],
      train_count: config["train_count"]
    }
  end

  defp implementation_identity do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)

    %{
      "git_commit" => String.trim(commit),
      "optimizer_module" => "Imp.Optimizer.Playbook",
      "campaign_module" => "Imp.Optimizer.Playbook.Campaign",
      "source_sha256" => Map.new(@implementation_sources, &{&1, sha256(File.read!(&1))})
    }
  end

  defp atomic_write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, contents, [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp dump_usage(usage) do
    %{
      "requests" => usage.requests,
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cost_usd" => usage.cost_usd,
      "authority" => Atom.to_string(usage.authority),
      "models" => usage.models
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
