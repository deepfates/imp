defmodule Imp.Optimizer.MIPROv2.Checkpoint do
  @moduledoc false

  alias Imp.Optimizer.{Report, Sampling, SearchPolicy}
  alias Imp.Optimizer.MIPROv2.{OptunaStartupPolicy, OptunaTPEPolicy, PythonRandom}
  alias Imp.Optimizer.SearchPolicy.CategoricalTPE

  @type_name "imp_mipro_v2_run"
  @schema_version 2

  @spec dump(map(), map(), map()) :: map()
  def dump(compatibility, artifacts, state)
      when is_map(compatibility) and is_map(artifacts) and is_map(state) do
    payload = %{
      "compatibility" => compatibility,
      "artifacts" => Report.encode_term(artifacts),
      "state" => %{
        "policy" => SearchPolicy.dump(state.policy),
        "rng" => dump_rng(state.rng),
        "trials" => dump_records(state.trials),
        "combo_scores" => state.combo_scores,
        "full_evaluations" => dump_records(state.full_evaluations),
        "next_study_number" => state.next_study_number,
        "evaluation_calls" => state.evaluation_calls,
        "errors" => Report.encode_term(state.errors)
      }
    }

    %{
      "type" => @type_name,
      "schema_version" => @schema_version,
      "payload_sha256" => checksum(payload),
      "payload" => payload
    }
  end

  @spec load!(map(), map()) :: %{artifacts: map(), state: map()}
  def load!(checkpoint, expected_compatibility)

  def load!(
        %{
          "type" => @type_name,
          "schema_version" => schema_version,
          "payload_sha256" => payload_sha256,
          "payload" =>
            %{
              "compatibility" => compatibility,
              "artifacts" => artifacts,
              "state" => state
            } = payload
        },
        expected_compatibility
      )
      when schema_version in [1, @schema_version] and is_map(compatibility) and
             is_map(expected_compatibility) and is_map(artifacts) and is_map(state) do
    unless checksum(payload) == payload_sha256 do
      raise ArgumentError, "MIPROv2 resume state checksum does not match its payload"
    end

    unless compatible?(schema_version, compatibility, expected_compatibility) do
      raise ArgumentError,
            "MIPROv2 resume state does not match the program runtime, datasets, or search configuration"
    end

    loaded = %{
      policy:
        state
        |> Map.fetch!("policy")
        |> SearchPolicy.load!([CategoricalTPE, OptunaStartupPolicy, OptunaTPEPolicy]),
      rng: state |> Map.fetch!("rng") |> load_rng!(schema_version),
      trials: state |> Map.fetch!("trials") |> load_records!("trials"),
      combo_scores: fetch_score_map!(state, "combo_scores"),
      full_evaluations:
        state |> Map.fetch!("full_evaluations") |> load_records!("full_evaluations"),
      next_study_number: fetch_non_negative_integer!(state, "next_study_number"),
      evaluation_calls: fetch_non_negative_integer!(state, "evaluation_calls"),
      errors: state |> Map.fetch!("errors") |> Report.decode_term()
    }

    validate_state!(loaded)
    validate_rng_contract!(loaded, schema_version, expected_compatibility)
    %{artifacts: Report.decode_term(artifacts), state: loaded}
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid MIPROv2 resume state: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(value, _expected_compatibility) do
    raise ArgumentError, "invalid MIPROv2 resume state: #{inspect(value)}"
  end

  defp dump_records(records) do
    records
    |> Enum.map(&Map.drop(&1, [:program]))
    |> Report.encode_term()
  end

  defp load_records!(records, name) when is_list(records) do
    records = Report.decode_term(records)

    unless Enum.all?(records, &valid_record?/1) do
      raise ArgumentError, "MIPROv2 checkpoint #{name} contain an invalid record"
    end

    records
  end

  defp load_records!(value, name) do
    raise ArgumentError, "MIPROv2 checkpoint #{name} must be a list, got: #{inspect(value)}"
  end

  defp valid_record?(%{sampled_indices: sampled_indices, example_count: example_count} = record)
       when is_list(sampled_indices) and is_integer(example_count) and example_count >= 0 do
    Map.delete(record, :sampled_indices)
    |> Map.delete(:example_count)
    |> valid_record?() and
      length(sampled_indices) == example_count and
      Enum.uniq(sampled_indices) == sampled_indices and
      Enum.all?(sampled_indices, &(is_integer(&1) and &1 >= 0)) and
      Map.get(record, :evaluation_scope) in [:minibatch, :full_validation]
  end

  defp valid_record?(%{trial: trial, params: params, score: score}) do
    is_integer(trial) and trial >= 0 and is_map(params) and is_number(score)
  end

  defp valid_record?(_record), do: false

  defp fetch_score_map!(state, key) do
    case Map.fetch!(state, key) do
      scores when is_map(scores) ->
        if Enum.all?(scores, fn {key, values} ->
             is_binary(key) and is_list(values) and Enum.all?(values, &is_number/1)
           end) do
          scores
        else
          raise ArgumentError, "MIPROv2 checkpoint #{key} is invalid"
        end

      value ->
        raise ArgumentError, "MIPROv2 checkpoint #{key} must be a map, got: #{inspect(value)}"
    end
  end

  defp fetch_non_negative_integer!(state, key) do
    case Map.fetch!(state, key) do
      value when is_integer(value) and value >= 0 -> value
      value -> raise ArgumentError, "MIPROv2 checkpoint #{key} is invalid: #{inspect(value)}"
    end
  end

  defp validate_state!(state) do
    trial_numbers = Enum.map(state.trials, & &1.trial)

    expected_trial_numbers =
      if trial_numbers == [], do: [], else: Enum.to_list(1..length(trial_numbers))

    unless trial_numbers == expected_trial_numbers do
      raise ArgumentError, "MIPROv2 checkpoint trials are not contiguous"
    end

    unless match?([%{trial: 0, kind: :baseline} | _], state.full_evaluations) do
      raise ArgumentError, "MIPROv2 checkpoint is missing its baseline evaluation"
    end

    unless is_list(state.errors) do
      raise ArgumentError, "MIPROv2 checkpoint errors must be a list"
    end

    expected_observations =
      length(state.trials) +
        Enum.count(state.full_evaluations, &(&1.kind in [:baseline, :promoted_full]))

    unless state.next_study_number == expected_observations do
      raise ArgumentError,
            "MIPROv2 checkpoint study number does not match its objective and full evaluations"
    end

    case state.policy do
      %SearchPolicy{
        module: OptunaStartupPolicy,
        state: %{completed_trials: completed_trials}
      } ->
        unless completed_trials == expected_observations do
          raise ArgumentError,
                "MIPROv2 Optuna startup checkpoint completed-trial count does not match its trials"
        end

      %SearchPolicy{
        module: OptunaTPEPolicy,
        state: %{observations: observations}
      } ->
        unless length(observations) == expected_observations do
          raise ArgumentError,
                "MIPROv2 Optuna TPE checkpoint observation count does not match its trials"
        end

      _other ->
        :ok
    end

    state
  end

  defp dump_rng(%PythonRandom{} = rng),
    do: %{"kind" => "python_random", "state" => PythonRandom.dump(rng)}

  defp dump_rng(rng), do: %{"kind" => "beam_sampling", "state" => Sampling.dump(rng)}

  defp load_rng!(rng, 1), do: Sampling.load!(rng)

  defp load_rng!(%{"kind" => "python_random", "state" => state} = rng, @schema_version)
       when map_size(rng) == 2,
       do: PythonRandom.load!(state)

  defp load_rng!(%{"kind" => "beam_sampling", "state" => state} = rng, @schema_version)
       when map_size(rng) == 2,
       do: Sampling.load!(state)

  defp load_rng!(rng, @schema_version),
    do: raise(ArgumentError, "invalid MIPROv2 checkpoint RNG: #{inspect(rng)}")

  defp compatible?(@schema_version, compatibility, expected), do: compatibility == expected

  defp compatible?(1, %{"sha256" => digest}, %{"sha256" => digest}), do: true
  defp compatible?(_schema_version, _compatibility, _expected), do: false

  defp validate_rng_contract!(state, schema_version, expected_compatibility) do
    expected_kind = Map.fetch!(expected_compatibility, "search_evaluation_rng")
    actual_kind = rng_kind(state.rng)
    exact_policy? = state.policy.module in [OptunaStartupPolicy, OptunaTPEPolicy]
    minibatch_records? = Enum.any?(state.trials, &(&1.kind == :minibatch))

    cond do
      schema_version == 1 and expected_kind == "python_random" ->
        raise ArgumentError,
              "schema-one MIPROv2 checkpoints cannot contain pinned minibatch RNG state"

      actual_kind != expected_kind ->
        raise ArgumentError,
              "MIPROv2 checkpoint RNG kind does not match the resolved search configuration"

      actual_kind == "python_random" and not exact_policy? ->
        raise ArgumentError,
              "MIPROv2 checkpoint Python RNG requires a pinned Optuna search policy"

      exact_policy? and minibatch_records? and actual_kind != "python_random" ->
        raise ArgumentError,
              "pinned Optuna minibatch checkpoint requires Python random state"

      true ->
        :ok
    end
  end

  defp rng_kind(%PythonRandom{}), do: "python_random"
  defp rng_kind(_beam_state), do: "beam_sampling"

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
