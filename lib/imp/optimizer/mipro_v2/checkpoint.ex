defmodule Imp.Optimizer.MIPROv2.Checkpoint do
  @moduledoc false

  alias Imp.Optimizer.{Report, Sampling, SearchPolicy}

  @type_name "imp_mipro_v2_run"
  @schema_version 1

  @spec dump(map(), map(), map()) :: map()
  def dump(compatibility, artifacts, state)
      when is_map(compatibility) and is_map(artifacts) and is_map(state) do
    payload = %{
      "compatibility" => compatibility,
      "artifacts" => Report.encode_term(artifacts),
      "state" => %{
        "policy" => SearchPolicy.dump(state.policy),
        "rng" => Sampling.dump(state.rng),
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
  def load!(
        %{
          "type" => @type_name,
          "schema_version" => @schema_version,
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
      when is_map(compatibility) and is_map(expected_compatibility) and is_map(artifacts) and
             is_map(state) do
    unless checksum(payload) == payload_sha256 do
      raise ArgumentError, "MIPROv2 resume state checksum does not match its payload"
    end

    unless compatibility == expected_compatibility do
      raise ArgumentError,
            "MIPROv2 resume state does not match the program, datasets, or search configuration"
    end

    loaded = %{
      policy: state |> Map.fetch!("policy") |> SearchPolicy.load!(),
      rng: state |> Map.fetch!("rng") |> Sampling.load!(),
      trials: state |> Map.fetch!("trials") |> load_records!("trials"),
      combo_scores: fetch_score_map!(state, "combo_scores"),
      full_evaluations:
        state |> Map.fetch!("full_evaluations") |> load_records!("full_evaluations"),
      next_study_number: fetch_non_negative_integer!(state, "next_study_number"),
      evaluation_calls: fetch_non_negative_integer!(state, "evaluation_calls"),
      errors: state |> Map.fetch!("errors") |> Report.decode_term()
    }

    validate_state!(loaded)
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

    state
  end

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
