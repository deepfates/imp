defmodule Imp.Optimizer.COPRO do
  @behaviour Imp.Optimizer
  @moduledoc """
  DSPy 3.2.1 coordinate prompt optimizer.

  COPRO searches, stores, compares, and deduplicates `(instruction, prefix)`
  metadata as DSPy 3.2.1 does. DSPy declares `prefix` deprecated and does not
  render it into task prompts; Imp behaves the same way. Only instruction
  changes affect task prompts.

  A configured proposal LM may return the whole requested JSON batch. If it
  returns one candidate, Imp performs ordered, bounded fan-out with distinct
  rollout IDs until the requested batch is complete. A proposal LM must be set
  explicitly on the optimizer or in Imp settings. COPRO never substitutes
  canned suffixes for a missing proposer, including when the task program has
  its own LM. `:extra_instructions` are explicit candidate seeds; when present,
  they are evaluated before LM-generated proposals but do not silently replace
  the required proposal model.

  `proposal_response_format: :required` sends an exact JSON Schema and validates
  the returned batch before any candidate evaluation. `:auto` does so when the
  configured LM advertises schema support; `:off` preserves DSPy's tolerant text
  compatibility path.

  For statistics fidelity, `results_latest` preserves 3.2.1's cumulative
  `latest_scores` behavior across predictors within each depth.

  Ordinary proposal and task failures follow COPRO's bounded error behavior.
  Operational route, cost, budget, transport, and cancellation guards remain
  fatal through both proposal fan-out and candidate evaluation.
  """

  defstruct [
    :metric,
    :proposer_lm,
    breadth: 10,
    depth: 3,
    init_temperature: 1.4,
    track_stats: false,
    extra_instructions: [],
    proposal_max_concurrency: 4,
    proposal_response_format: :off
  ]

  @option_schema [
    breadth: [type: :non_neg_integer, default: 10],
    depth: [type: :non_neg_integer, default: 3],
    init_temperature: [type: {:or, [:integer, :float]}, default: 1.4],
    track_stats: [type: :boolean, default: false],
    proposer_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    extra_instructions: [type: {:list, :string}, default: []],
    proposal_max_concurrency: [type: :pos_integer, default: 4],
    proposal_response_format: [type: {:in, [:off, :auto, :required]}, default: :off]
  ]

  @eval_option_schema [
    num_threads: [type: {:custom, __MODULE__, :validate_optional_positive, []}, default: nil],
    max_errors: [type: {:custom, __MODULE__, :validate_optional_max_errors, []}, default: nil]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.COPRO.new/2", "metric")
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.COPRO.new/2")

    if opts[:breadth] <= 1, do: raise(ArgumentError, "Breadth must be greater than 1")

    struct(__MODULE__, Map.new(opts) |> Map.put(:metric, metric))
  end

  @doc false
  def validate_optional_positive(nil), do: {:ok, nil}
  def validate_optional_positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  def validate_optional_positive(_value), do: {:error, "expected nil or a positive integer"}

  @doc false
  def validate_optional_max_errors(nil), do: {:ok, nil}
  def validate_optional_max_errors(value), do: Imp.Evaluate.validate_max_errors(value)

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :optional},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    eval_opts = Imp.Optimizer.invocation_options(opts)

    {:ok,
     compile(
       optimizer,
       program,
       Imp.Optimizer.fetch_dataset!(opts, :trainset),
       Keyword.get(opts, :validation, []),
       eval_opts
     )}
  end

  @impl true
  def validate_invocation_options(opts) do
    _validated =
      Imp.Options.validate!(opts, @eval_option_schema, "Imp.Optimizer.COPRO.compile/5")

    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  # `devset` remains accepted for the Imp optimizer contract. DSPy's COPRO
  # scores coordinate candidates on `trainset`, so it is not used for selection.
  @doc false
  def compile(%__MODULE__{} = optimizer, program, trainset, _devset \\ [], eval_opts \\ []) do
    optimizer = %{optimizer | proposer_lm: resolve_proposer_lm!(optimizer)}
    trainset = Enum.to_list(trainset)
    predictors = Imp.ProgramParameters.predictors(program)

    if predictors == [],
      do: raise(ArgumentError, "COPRO requires at least one optimizer predictor")

    eval_opts =
      Imp.Options.validate!(eval_opts, @eval_option_schema, "Imp.Optimizer.COPRO.compile/5")

    {max_errors, max_errors_source} = resolve_max_errors!(eval_opts[:max_errors])
    eval_opts = Keyword.put(eval_opts, :max_errors, max_errors)

    initial =
      Map.new(predictors, fn %{name: name, predictor: predictor} ->
        {name, initial_pairs(predictor, optimizer)}
      end)

    state = %{
      current: program,
      latest: initial,
      all: initial,
      evaluated: Map.new(predictors, &{&1.name, %{}}),
      errors: [],
      total_calls: 0,
      rounds: [],
      last_depth: nil,
      results_best: stats_for(predictors),
      results_latest: stats_for(predictors)
    }

    depths = if optimizer.depth == 0, do: [], else: Enum.to_list(0..(optimizer.depth - 1))

    state =
      Enum.reduce(depths, state, fn depth, state ->
        run_round(depth, state, predictors, trainset, optimizer, eval_opts)
      end)

    finalize(state, predictors, optimizer, max_errors, max_errors_source)
  end

  defp run_round(depth, state, predictors, trainset, optimizer, eval_opts) do
    {state, round_records, _latest_scores} =
      Enum.reduce(predictors, {state, [], []}, fn %{name: name},
                                                  {state, round_records, latest_scores} ->
        pairs = if length(predictors) > 1, do: state.all[name], else: state.latest[name]
        pair_count = length(pairs)

        {evaluated, errors, calls, latest_scores, records} =
          Enum.reduce(
            Enum.with_index(pairs),
            {state.evaluated[name], state.errors, state.total_calls, latest_scores, []},
            fn {pair, ordinal}, {evaluated, errors, calls, latest_scores, records} ->
              candidate = put_pair(state.current, name, pair)

              result =
                Imp.Telemetry.span(
                  [:imp, :optimizer, :trial],
                  %{optimizer: :copro, predictor: name, depth: depth, trial: ordinal},
                  fn -> evaluate!(candidate, trainset, optimizer.metric, eval_opts) end
                )

              record = %{
                score: result.score,
                subscores: result.subscores,
                program: candidate,
                instruction: elem(pair, 0),
                prefix: elem(pair, 1),
                depth: depth
              }

              evaluated = retain_candidate(evaluated, pair, record)

              latest_scores =
                if pair_count - optimizer.breadth <= ordinal,
                  do: latest_scores ++ [result.score],
                  else: latest_scores

              errors =
                errors ++
                  contextualize_errors(result.errors, name, depth, ordinal)

              {evaluated, errors, calls + 1, latest_scores, records ++ [record]}
            end
          )

        best = evaluated |> ordered_records() |> stable_score_sort() |> hd()
        current = put_pair(state.current, name, {best.instruction, best.prefix})

        state =
          %{
            state
            | current: current,
              evaluated: Map.put(state.evaluated, name, evaluated),
              errors: errors,
              total_calls: calls
          }
          |> put_latest_stats(name, depth, latest_scores, optimizer.track_stats)

        records = Enum.map(records, &Map.put(&1, :predictor, name))
        {state, round_records ++ records, latest_scores}
      end)

    report_candidates =
      Enum.map(round_records, &Map.drop(&1, [:program, :insertion_order]))

    state = %{
      state
      | rounds: state.rounds ++ [%{depth: depth, candidates: report_candidates}],
        last_depth: depth
    }

    if depth == optimizer.depth - 1 do
      state
    else
      {latest, all, results_best} = next_pairs(state, predictors, depth, optimizer)
      %{state | latest: latest, all: all, results_best: results_best}
    end
  end

  defp retain_candidate(evaluated, pair, record) do
    case Map.fetch(evaluated, pair) do
      :error ->
        Map.put(evaluated, pair, Map.put(record, :insertion_order, map_size(evaluated)))

      {:ok, %{score: previous}} when previous >= record.score ->
        evaluated

      {:ok, previous} ->
        Map.put(evaluated, pair, Map.put(record, :insertion_order, previous.insertion_order))
    end
  end

  defp ordered_records(evaluated),
    do: evaluated |> Map.values() |> Enum.sort_by(& &1.insertion_order)

  defp stable_score_sort(records),
    do: Enum.sort_by(records, &{-&1.score, &1.insertion_order})

  defp next_pairs(state, predictors, depth, optimizer) do
    Enum.reduce(predictors, {%{}, state.all, state.results_best}, fn %{
                                                                       name: name,
                                                                       predictor: predictor
                                                                     },
                                                                     {latest, all, results_best} ->
      records = state.evaluated[name] |> ordered_records() |> stable_score_sort()
      top = Enum.take(records, optimizer.breadth)
      history = Enum.reverse(top)
      generated = proposal_pairs(predictor, history, optimizer, optimizer.breadth)
      latest = Map.put(latest, name, generated)
      all = Map.update!(all, name, &(&1 ++ generated))
      results_best = put_best_stats(results_best, name, depth, records, optimizer.track_stats)
      {latest, all, results_best}
    end)
  end

  defp finalize(state, predictors, optimizer, max_errors, max_errors_source) do
    results_best = append_final_best_stats(state, predictors, optimizer)

    candidates =
      predictors
      |> Enum.flat_map(fn %{name: name} ->
        state.evaluated[name]
        |> ordered_records()
        |> Enum.map(&Map.put(&1, :predictor, name))
      end)
      |> Enum.with_index()
      |> Enum.sort_by(fn {candidate, global_order} -> {-candidate.score, global_order} end)
      |> Enum.map(&elem(&1, 0))
      |> drop_duplicates()

    case candidates do
      [] ->
        raise RuntimeError, "COPRO did not produce an evaluated candidate"

      [best | _] ->
        metadata = %{
          breadth: optimizer.breadth,
          depth: optimizer.depth,
          total_calls: state.total_calls,
          rounds: state.rounds,
          evaluation_dataset: :trainset,
          score_scale: :percentage,
          prefix_behavior: :stored_compared_but_not_rendered,
          proposal_mode: proposal_mode(optimizer),
          proposal_response_format: optimizer.proposal_response_format,
          proposal_batching: :whole_batch_or_ordered_bounded_fanout,
          latest_score_scope: :cumulative_across_predictors_per_depth,
          max_errors: max_errors,
          max_errors_source: max_errors_source,
          status: if(state.errors == [], do: :ok, else: :with_errors)
        }

        metadata =
          if optimizer.track_stats do
            Map.merge(metadata, %{
              results_best: results_best,
              results_latest: state.results_latest
            })
          else
            metadata
          end

        report =
          Imp.Optimizer.Report.new(%{
            optimizer: :copro,
            best_score: best.score,
            candidate_count: length(candidates),
            candidates: Enum.map(candidates, &Map.drop(&1, [:program, :insertion_order])),
            errors: state.errors,
            metadata: metadata
          })

        attach_report(best.program, report)
    end
  end

  defp append_final_best_stats(state, _predictors, %{track_stats: false}),
    do: state.results_best

  defp append_final_best_stats(%{last_depth: nil} = state, _predictors, _optimizer),
    do: state.results_best

  defp append_final_best_stats(state, predictors, _optimizer) do
    Enum.reduce(predictors, state.results_best, fn %{name: name}, stats ->
      records = state.evaluated[name] |> ordered_records() |> stable_score_sort()
      put_best_stats(stats, name, state.last_depth, records, true)
    end)
  end

  defp initial_pairs(predictor, optimizer) do
    base = {predictor.signature.instructions, output_prefix(predictor)}
    proposal_pairs(predictor, [], optimizer, optimizer.breadth - 1) ++ [base]
  end

  defp proposal_mode(optimizer) do
    if optimizer.proposer_lm, do: :language_model, else: :missing
  end

  defp proposal_pairs(_predictor, _history, _optimizer, 0), do: []

  defp proposal_pairs(predictor, history, optimizer, count) do
    prefix = output_prefix(predictor)
    explicit = optimizer.extra_instructions |> Enum.take(count) |> Enum.map(&{&1, prefix})
    missing = count - length(explicit)

    explicit ++
      if missing == 0 do
        []
      else
        provider_proposal_pairs!(optimizer.proposer_lm, predictor, history, optimizer, missing)
      end
  end

  defp resolve_proposer_lm!(optimizer) do
    case optimizer.proposer_lm || Imp.Settings.snapshot() |> Map.fetch!(:lm) do
      nil ->
        raise ArgumentError,
              "COPRO requires :proposer_lm or an Imp settings :lm; it does not synthesize proposal suffixes"

      lm ->
        lm
    end
  end

  defp provider_proposal_pairs!(lm, predictor, history, optimizer, count) do
    prefix = output_prefix(predictor)

    first_raw =
      request_proposals!(lm, predictor, history, optimizer, count,
        rollout_id: 0,
        candidate_index: 1
      )

    first_pairs =
      parse_pairs(
        first_raw,
        prefix,
        count,
        proposal_response_format_enabled?(lm, optimizer.proposal_response_format)
      )

    if first_pairs == [] do
      raise RuntimeError, "COPRO proposal LM returned no instruction/prefix candidate"
    end

    missing = count - length(first_pairs)

    if missing <= 0 do
      Enum.take(first_pairs, count)
    else
      first_pairs ++
        fan_out_proposals!(
          lm,
          predictor,
          history,
          optimizer,
          prefix,
          length(first_pairs),
          missing
        )
    end
  end

  defp fan_out_proposals!(lm, predictor, history, optimizer, prefix, completed, missing) do
    1..missing
    |> Imp.Tasks.async_stream(
      fn rollout_id ->
        case request_proposals(lm, predictor, history, optimizer, 1,
               rollout_id: rollout_id,
               candidate_index: completed + rollout_id
             ) do
          {:ok, raw} ->
            case parse_pairs(
                   raw,
                   prefix,
                   1,
                   proposal_response_format_enabled?(lm, optimizer.proposal_response_format)
                 ) do
              [pair] -> {:ok, pair}
              [] -> {:error, :missing_candidate}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end,
      ordered: true,
      max_concurrency: min(missing, optimizer.proposal_max_concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, {:ok, pair}} ->
        pair

      {:ok, {:error, reason}} ->
        Imp.OperationalSafetyError.raise_if_present!(reason)
        raise RuntimeError, "COPRO proposal fan-out failed: #{inspect(reason)}"

      {:exit, reason} ->
        Imp.OperationalSafetyError.raise_if_present!(reason)
        raise RuntimeError, "COPRO proposal fan-out exited: #{inspect(reason)}"
    end)
  end

  defp request_proposals!(lm, predictor, history, optimizer, count, opts) do
    case request_proposals(lm, predictor, history, optimizer, count, opts) do
      {:ok, raw} ->
        raw

      {:error, reason} ->
        Imp.OperationalSafetyError.raise_if_present!(reason)
        raise RuntimeError, "COPRO proposal LM failed: #{inspect(reason)}"
    end
  end

  defp request_proposals(lm, predictor, history, optimizer, count, opts) do
    messages = proposal_messages(predictor, history, count, opts[:candidate_index])

    generate_opts =
      [temperature: optimizer.init_temperature, rollout_id: opts[:rollout_id]]
      |> maybe_put_proposal_response_format(lm, optimizer.proposal_response_format, count)

    Imp.LM.generate(lm, messages, generate_opts)
    |> Imp.LM.Result.unwrap()
  end

  defp maybe_put_proposal_response_format(opts, _lm, :off, _count), do: opts

  defp maybe_put_proposal_response_format(opts, lm, :auto, count) do
    if Imp.LM.response_format_capability(lm).response_schema,
      do: Keyword.put(opts, :response_format, proposal_response_format(count)),
      else: opts
  end

  defp maybe_put_proposal_response_format(opts, _lm, :required, count),
    do: Keyword.put(opts, :response_format, proposal_response_format(count))

  defp proposal_response_format_enabled?(_lm, :off), do: false
  defp proposal_response_format_enabled?(_lm, :required), do: true

  defp proposal_response_format_enabled?(lm, :auto),
    do: Imp.LM.response_format_capability(lm).response_schema

  defp proposal_response_format(count) do
    %{
      type: "json_schema",
      json_schema: %{
        name: "imp_copro_proposals",
        strict: true,
        schema: %{
          "type" => "array",
          "minItems" => count,
          "maxItems" => count,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["proposed_instruction", "proposed_prefix_for_output_field"],
            "properties" => %{
              "proposed_instruction" => %{"type" => "string"},
              "proposed_prefix_for_output_field" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end

  defp proposal_messages(predictor, history, count, candidate_index) do
    attempts =
      history
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {record, index} ->
        [
          "Instruction ##{index}: #{record.instruction}",
          "Prefix ##{index}: #{record.prefix}",
          "Resulting Score ##{index}: #{record.score}"
        ]
      end)

    response_schema = %{
      type: "array",
      minItems: count,
      maxItems: count,
      items: %{
        type: "object",
        required: ["proposed_instruction", "proposed_prefix_for_output_field"],
        properties: %{
          proposed_instruction: %{type: "string"},
          proposed_prefix_for_output_field: %{type: "string"}
        }
      }
    }

    payload = %{
      attempted_instructions: attempts,
      basic_instruction: predictor.signature.instructions,
      requested_candidate_count: count,
      response_schema: response_schema,
      signature: Imp.Signature.to_spec(predictor.signature)
    }

    payload =
      if is_nil(candidate_index),
        do: payload,
        else: Map.put(payload, :candidate_index, candidate_index)

    [
      %{
        role: :system,
        content: proposal_system_message(history, count)
      },
      %{role: :user, content: Jason.encode!(payload)}
    ]
  end

  defp proposal_system_message([], count) do
    "You are an instruction optimizer for language models. Propose #{count} improved task " <>
      "instruction/output-prefix candidate(s) that should make a good language model perform " <>
      "the supplied signature well. Do not be afraid to be creative. Return exactly one JSON " <>
      "array matching the supplied schema."
  end

  defp proposal_system_message(_history, count) do
    "You are an instruction optimizer for language models. The supplied attempts are ordered " <>
      "from lower to higher score. Propose #{count} new task instruction/output-prefix " <>
      "candidate(s) that should perform even better. Do not be afraid to be creative. Return " <>
      "exactly one JSON array matching the supplied schema."
  end

  defp parse_pairs(raw, prefix, count, strict?) do
    raw
    |> decode_proposals(strict?, count)
    |> Enum.flat_map(fn
      %{
        "proposed_instruction" => instruction,
        "proposed_prefix_for_output_field" => proposed_prefix
      } ->
        [{clean(instruction), clean(proposed_prefix)}]

      %{proposed_instruction: instruction, proposed_prefix_for_output_field: proposed_prefix} ->
        [{clean(instruction), clean(proposed_prefix)}]

      instruction when is_binary(instruction) ->
        [{clean(instruction), prefix}]

      _ ->
        []
    end)
    |> Enum.reject(fn {instruction, _prefix} -> instruction == "" end)
    |> Enum.take(count)
  end

  defp decode_proposals(raw, false, _count), do: decode_raw(raw)

  defp decode_proposals(raw, true, count) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decode_proposals(decoded, true, count)
      {:error, _reason} -> []
    end
  end

  defp decode_proposals(values, true, count) when is_list(values) and length(values) == count do
    if Enum.all?(values, &strict_proposal?/1), do: values, else: []
  end

  defp decode_proposals(_raw, true, _count), do: []

  defp strict_proposal?(proposal) when is_map(proposal) and map_size(proposal) == 2 do
    instruction = proposal["proposed_instruction"] || proposal[:proposed_instruction]

    prefix =
      proposal["proposed_prefix_for_output_field"] ||
        proposal[:proposed_prefix_for_output_field]

    is_binary(instruction) and String.trim(instruction) != "" and is_binary(prefix)
  end

  defp strict_proposal?(_proposal), do: false

  defp decode_raw(raw) when is_list(raw), do: raw
  defp decode_raw(%{} = raw), do: [raw]

  defp decode_raw(raw) when is_binary(raw) do
    case decode_json_values(raw) do
      {:ok, values} ->
        values

      :error ->
        case fenced_json(raw) do
          {:ok, candidate} ->
            case decode_json_values(candidate) do
              {:ok, values} -> values
              :error -> []
            end

          :none ->
            raw
            |> String.split("\n", trim: true)
            |> Enum.reject(&(String.trim(&1) in ["```", "```json"]))
        end
    end
  end

  defp decode_raw(_raw), do: []

  defp decode_json_values(raw) do
    case Jason.decode(raw) do
      {:ok, values} when is_list(values) -> {:ok, values}
      {:ok, value} -> {:ok, [value]}
      {:error, _reason} -> :error
    end
  end

  defp fenced_json(raw) do
    case Regex.run(~r/```(?:json)?\s*\n(.*?)```/is, raw, capture: :all_but_first) do
      [candidate] -> {:ok, String.trim(candidate)}
      nil -> :none
    end
  end

  defp clean(value), do: value |> to_string() |> String.trim("\"") |> String.trim()

  defp evaluate!(program, trainset, metric, eval_opts) do
    max_errors = eval_opts[:max_errors]

    max_concurrency =
      eval_opts[:num_threads] || Imp.Settings.snapshot() |> Map.fetch!(:async_max_workers)

    # Imp.Evaluate halts at errors >= max_errors (DSPy
    # parallelizer semantics); translate into COPRO's budget error so the
    # optimizer-facing contract stays the same.
    result =
      try do
        Imp.Evaluate.new(trainset, metric,
          max_concurrency: max_concurrency,
          max_errors: max_errors
        )
        |> Imp.Evaluate.run(program)
      rescue
        cancelled in Imp.EvaluationCancelledError ->
          reraise RuntimeError,
                  "COPRO evaluation error budget exhausted: #{length(cancelled.errors)} errors " <>
                    "(maximum #{max_errors})",
                  __STACKTRACE__
      end

    enforce_error_budget!(result.errors, max_errors)

    %{
      score: dspy_percentage_score(result.rows),
      subscores: Enum.map(result.rows, & &1.score),
      errors: result.errors
    }
  end

  defp dspy_percentage_score([]),
    do: raise(ArithmeticError, "DSPy Evaluate cannot score an empty dataset")

  defp dspy_percentage_score(rows) do
    total = Enum.reduce(rows, 0, fn row, sum -> sum + row.score end)
    round_half_even(100 * total / length(rows), 2)
  end

  defp round_half_even(value, _digits) when value == 0.0, do: value

  defp round_half_even(value, digits) when is_float(value) do
    <<sign::1, exponent::11, fraction::52>> = <<value::float-64>>

    if exponent == 0x7FF do
      value
    else
      significand = if exponent == 0, do: fraction, else: Bitwise.bsl(1, 52) + fraction
      binary_exponent = if exponent == 0, do: -1074, else: exponent - 1023 - 52

      {numerator, denominator} =
        if binary_exponent >= 0 do
          {Bitwise.bsl(significand, binary_exponent), 1}
        else
          {significand, Bitwise.bsl(1, -binary_exponent)}
        end

      factor = Integer.pow(10, digits)
      scaled = numerator * factor
      quotient = div(scaled, denominator)
      remainder = rem(scaled, denominator)

      rounded =
        case compare(remainder * 2, denominator) do
          :lt -> quotient
          :gt -> quotient + 1
          :eq -> if rem(quotient, 2) == 0, do: quotient, else: quotient + 1
        end

      signed = if sign == 1, do: -rounded, else: rounded
      signed / factor
    end
  end

  defp compare(left, right) when left < right, do: :lt
  defp compare(left, right) when left > right, do: :gt
  defp compare(_left, _right), do: :eq

  defp enforce_error_budget!([], _max_errors), do: :ok
  defp enforce_error_budget!(_errors, :infinity), do: :ok

  defp enforce_error_budget!(errors, max_errors) do
    if length(errors) >= max_errors do
      raise RuntimeError,
            "COPRO evaluation error budget exhausted: #{length(errors)} errors (maximum #{max_errors})"
    end
  end

  defp contextualize_errors(errors, predictor, depth, ordinal) do
    Enum.map(errors, fn error ->
      Map.merge(
        %{predictor: predictor, depth: depth, candidate_index: ordinal, stage: :evaluation},
        Map.new(error)
      )
    end)
  end

  defp resolve_max_errors!(nil), do: resolve_settings_max_errors!()
  defp resolve_max_errors!(value), do: {validate_max_errors!(value), :explicit}

  defp resolve_settings_max_errors! do
    {Imp.Settings.fetch!(:max_errors) |> validate_max_errors!(), :settings}
  end

  defp validate_max_errors!(value) do
    case Imp.Evaluate.validate_max_errors(value) do
      {:ok, max_errors} ->
        max_errors

      {:error, message} ->
        raise ArgumentError, "invalid effective :max_errors setting: #{message}"
    end
  end

  defp put_pair(program, name, {instruction, prefix}) do
    Imp.ProgramParameters.update_predictor(program, name, fn predictor ->
      signature = predictor.signature
      output_index = length(signature.outputs) - 1
      outputs = List.update_at(signature.outputs, output_index, &%{&1 | prefix: prefix})

      Imp.Predict.Predict.with_signature(predictor, %{
        signature
        | instructions: instruction,
          outputs: outputs
      })
    end)
  end

  defp output_prefix(predictor),
    do: predictor.signature.outputs |> List.last() |> Map.fetch!(:prefix)

  defp drop_duplicates(candidates) do
    Enum.reduce(candidates, [], fn candidate, kept ->
      duplicate? =
        Enum.any?(kept, fn retained ->
          candidate.score == retained.score and same_program?(candidate.program, retained.program)
        end)

      if duplicate?, do: kept, else: kept ++ [candidate]
    end)
  end

  defp same_program?(left, right) do
    Enum.map(Imp.ProgramParameters.predictors(left), &signature_pair(&1.predictor)) ==
      Enum.map(Imp.ProgramParameters.predictors(right), &signature_pair(&1.predictor))
  end

  defp signature_pair(predictor), do: {predictor.signature.instructions, output_prefix(predictor)}

  defp attach_report(program, report) do
    case Imp.ProgramAccess.predict(program) do
      nil ->
        Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
          Imp.ProgramParameters.update_predictor(
            acc,
            name,
            &Imp.Optimizer.Report.attach(&1, report)
          )
        end)

      _predictor ->
        Imp.Optimizer.Report.attach(program, report)
    end
  end

  defp stats_for(predictors),
    do: Map.new(predictors, &{&1.name, %{depth: [], max: [], average: [], min: [], std: []}})

  defp put_latest_stats(state, _name, _depth, _scores, false), do: state

  defp put_latest_stats(state, name, depth, scores, true) when scores != [] do
    Map.update!(state.results_latest, name, &append_stats(&1, depth, scores))
    |> then(&%{state | results_latest: &1})
  end

  defp put_latest_stats(state, _name, _depth, _scores, true), do: state
  defp put_best_stats(stats, _name, _depth, _records, false), do: stats

  defp put_best_stats(stats, name, depth, records, true) when records != [] do
    scores = records |> Enum.take(10) |> Enum.map(& &1.score)
    Map.update!(stats, name, &append_stats(&1, depth, scores))
  end

  defp put_best_stats(stats, _name, _depth, _records, true), do: stats

  defp append_stats(stats, depth, scores) do
    average = Enum.sum(scores) / length(scores)
    variance = Enum.sum(Enum.map(scores, &:math.pow(&1 - average, 2))) / length(scores)

    %{
      depth: stats.depth ++ [depth],
      max: stats.max ++ [Enum.max(scores)],
      average: stats.average ++ [average],
      min: stats.min ++ [Enum.min(scores)],
      std: stats.std ++ [:math.sqrt(variance)]
    }
  end
end
