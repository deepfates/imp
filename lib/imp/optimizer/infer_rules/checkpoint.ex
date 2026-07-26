defmodule Imp.Optimizer.InferRules.Checkpoint do
  @moduledoc false

  alias Imp.Optimizer.Report

  @type_name "imp_infer_rules_run"
  @schema_version 1

  @spec dump(map(), map()) :: map()
  def dump(compatibility, state) when is_map(compatibility) and is_map(state) do
    payload = %{
      "compatibility" => compatibility,
      "state" => state |> dump_state() |> Report.encode_term()
    }

    checkpoint = %{
      "type" => @type_name,
      "schema_version" => @schema_version,
      "payload_sha256" => checksum(payload),
      "payload" => payload
    }

    Jason.encode!(checkpoint)
    checkpoint
  end

  @spec load!(map(), map(), struct()) :: map()
  def load!(
        %{
          "type" => @type_name,
          "schema_version" => @schema_version,
          "payload_sha256" => payload_sha256,
          "payload" => %{"compatibility" => compatibility, "state" => encoded_state} = payload
        },
        expected_compatibility,
        runtime_program
      )
      when is_binary(payload_sha256) and is_map(compatibility) and
             is_map(expected_compatibility) and is_map(encoded_state) and
             is_struct(runtime_program) do
    unless checksum(payload) == payload_sha256 do
      raise ArgumentError, "InferRules resume state checksum does not match its payload"
    end

    unless compatibility == expected_compatibility do
      raise ArgumentError,
            "InferRules resume state does not match the program runtime, datasets, or configuration"
    end

    state = encoded_state |> Report.decode_term() |> load_state!(runtime_program)
    validate_state!(state)
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid InferRules resume state: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(value, _expected_compatibility, _runtime_program) do
    raise ArgumentError, "invalid InferRules resume state: #{inspect(value)}"
  end

  defp dump_state(state) do
    state
    |> Map.update!(:baseline, &dump_optional_program/1)
    |> Map.update!(:candidates, &Enum.map(&1, fn row -> dump_program_row(row) end))
    |> Map.update!(:evaluated, &Enum.map(&1, fn row -> dump_program_row(row) end))
  end

  defp load_state!(state, runtime_program) when is_map(state) do
    state
    |> Map.update!(:baseline, &load_optional_program!(&1, runtime_program))
    |> Map.update!(:candidates, &load_program_rows!(&1, runtime_program, :candidates))
    |> Map.update!(:evaluated, &load_program_rows!(&1, runtime_program, :evaluated))
  end

  defp load_state!(value, _runtime_program),
    do: raise(ArgumentError, "InferRules checkpoint state must be a map, got: #{inspect(value)}")

  defp dump_optional_program(nil), do: nil
  defp dump_optional_program(program), do: dump_program(program)

  defp load_optional_program!(nil, _runtime_program), do: nil

  defp load_optional_program!(snapshot, runtime_program),
    do: load_program!(snapshot, runtime_program)

  defp dump_program_row(row), do: Map.update!(row, :program, &dump_program/1)

  defp load_program_rows!(rows, runtime_program, _name) when is_list(rows) do
    Enum.map(rows, fn
      %{program: snapshot} = row ->
        Map.put(row, :program, load_program!(snapshot, runtime_program))

      row ->
        raise ArgumentError, "InferRules checkpoint program row is invalid: #{inspect(row)}"
    end)
  end

  defp load_program_rows!(value, _runtime_program, name),
    do:
      raise(ArgumentError, "InferRules checkpoint #{name} must be a list, got: #{inspect(value)}")

  defp dump_program(program) do
    %{
      predictors:
        Enum.map(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
          %{
            name: name,
            instruction: predictor.signature.instructions,
            demos: predictor.demos
          }
        end)
    }
  end

  defp load_program!(%{predictors: snapshots}, runtime_program) when is_list(snapshots) do
    runtime_names = Enum.map(Imp.ProgramParameters.predictors(runtime_program), & &1.name)

    unless Enum.map(snapshots, & &1.name) == runtime_names do
      raise ArgumentError,
            "InferRules checkpoint predictor names do not match the runtime program"
    end

    Enum.reduce(snapshots, runtime_program, fn snapshot, program ->
      unless is_binary(snapshot.instruction) and is_list(snapshot.demos) do
        raise ArgumentError, "InferRules checkpoint predictor snapshot is invalid"
      end

      program
      |> Imp.ProgramParameters.put_instruction(snapshot.name, snapshot.instruction)
      |> Imp.ProgramParameters.put_demos(snapshot.name, snapshot.demos)
    end)
  end

  defp load_program!(value, _runtime_program),
    do: raise(ArgumentError, "InferRules checkpoint program is invalid: #{inspect(value)}")

  defp validate_state!(state) do
    required = [
      :baseline,
      :bootstrap_summary,
      :evaluation_max_errors,
      :proposals_complete,
      :next_candidate_index,
      :proposal_cursor,
      :candidates,
      :proposal_errors,
      :proposal_calls,
      :proposal_attempts,
      :evaluated,
      :completed_operations
    ]

    unless Enum.sort(Map.keys(state)) == Enum.sort(required) do
      raise ArgumentError, "InferRules checkpoint state has unknown or missing fields"
    end

    unless is_boolean(state.proposals_complete) and is_list(state.candidates) and
             is_list(state.proposal_errors) and is_list(state.evaluated) and
             non_negative_integer?(state.next_candidate_index) and
             non_negative_integer?(state.proposal_calls) and
             non_negative_integer?(state.proposal_attempts) and
             non_negative_integer?(state.completed_operations) and
             valid_cursor?(state.proposal_cursor) do
      raise ArgumentError, "InferRules checkpoint state is invalid"
    end

    if is_nil(state.baseline) and
         (not is_nil(state.bootstrap_summary) or state.candidates != [] or state.evaluated != [] or
            state.completed_operations != 0) do
      raise ArgumentError, "InferRules checkpoint contains work without a bootstrap baseline"
    end

    state
  end

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(%{candidate_index: index, predictor_index: predictor, rules: rules}),
    do: non_negative_integer?(index) and non_negative_integer?(predictor) and is_map(rules)

  defp valid_cursor?(_cursor), do: false

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
