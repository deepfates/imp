defmodule Imp.Optimizer.BootstrapFewShotWithRandomSearch.Checkpoint do
  @moduledoc false

  alias Imp.Optimizer.Report

  @type_name "imp_random_search_run"
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
      raise ArgumentError,
            "BootstrapFewShotWithRandomSearch resume state checksum does not match its payload"
    end

    unless compatibility == expected_compatibility do
      raise ArgumentError,
            "BootstrapFewShotWithRandomSearch resume state does not match the program runtime, datasets, or configuration"
    end

    state = encoded_state |> Report.decode_term() |> load_state!(runtime_program)
    validate_state!(state)
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid BootstrapFewShotWithRandomSearch resume state: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def load!(value, _expected_compatibility, _runtime_program) do
    raise ArgumentError,
          "invalid BootstrapFewShotWithRandomSearch resume state: #{inspect(value)}"
  end

  defp dump_state(state) do
    Map.update!(state, :records, fn records ->
      Enum.map(records, &Map.update!(&1, :program, fn program -> dump_program(program) end))
    end)
  end

  defp load_state!(state, runtime_program) when is_map(state) do
    Map.update!(state, :records, fn records -> load_records!(records, runtime_program) end)
  end

  defp load_state!(value, _runtime_program),
    do:
      raise(
        ArgumentError,
        "BootstrapFewShotWithRandomSearch checkpoint state must be a map, got: #{inspect(value)}"
      )

  defp load_records!(records, runtime_program) when is_list(records) do
    Enum.map(records, fn
      %{program: snapshot} = record ->
        Map.put(record, :program, load_program!(snapshot, runtime_program))

      record ->
        raise ArgumentError,
              "BootstrapFewShotWithRandomSearch checkpoint record is invalid: #{inspect(record)}"
    end)
  end

  defp load_records!(value, _runtime_program),
    do:
      raise(
        ArgumentError,
        "BootstrapFewShotWithRandomSearch checkpoint records must be a list: #{inspect(value)}"
      )

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
            "BootstrapFewShotWithRandomSearch checkpoint predictor names do not match the runtime program"
    end

    Enum.reduce(snapshots, runtime_program, fn snapshot, program ->
      unless is_binary(snapshot.instruction) and is_list(snapshot.demos) do
        raise ArgumentError,
              "BootstrapFewShotWithRandomSearch checkpoint predictor snapshot is invalid"
      end

      program
      |> Imp.ProgramParameters.put_instruction(snapshot.name, snapshot.instruction)
      |> Imp.ProgramParameters.put_demos(snapshot.name, snapshot.demos)
    end)
  end

  defp load_program!(value, _runtime_program),
    do:
      raise(
        ArgumentError,
        "BootstrapFewShotWithRandomSearch checkpoint program is invalid: #{inspect(value)}"
      )

  defp validate_state!(state) do
    unless Enum.sort(Map.keys(state)) == [:errors, :next_index, :records, :stopped] and
             is_list(state.records) and is_list(state.errors) and
             is_integer(state.next_index) and state.next_index >= 0 and
             is_boolean(state.stopped) and Enum.all?(state.records, &valid_record?/1) do
      raise ArgumentError, "BootstrapFewShotWithRandomSearch checkpoint state is invalid"
    end

    state
  end

  defp valid_record?(record) do
    is_integer(record.seed) and is_integer(record.evaluation_order) and
      record.evaluation_order >= 0 and is_number(record.score) and is_list(record.subscores) and
      Enum.all?(record.subscores, &is_number/1) and is_struct(record.program)
  end

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
