defmodule DSEx.Optimizer.SIMBA.Checkpoint do
  @moduledoc false

  alias DSEx.Optimizer.{Report, Sampling, SearchPolicy}
  alias DSEx.Optimizer.SIMBA.Population

  @type_name "dsex_simba_run"
  @schema_version 1

  @spec dump(map(), map()) :: map()
  def dump(compatibility, state) when is_map(compatibility) and is_map(state) do
    payload = %{
      "compatibility" => compatibility,
      "state" => %{
        "completed_steps" => state.completed_steps,
        "population" => dump_population(state.population),
        "winning_programs" => Enum.map(state.winning_programs, &dump_program/1),
        "trial_logs" => Report.json_safe(state.trial_logs),
        "order" => state.order,
        "cursor" => state.cursor,
        "poisson_rng" => Sampling.dump(state.poisson_rng),
        "errors" => Report.json_safe(state.errors),
        "trajectory_calls" => state.trajectory_calls,
        "candidate_evaluation_calls" => state.candidate_evaluation_calls,
        "final_evaluation_calls" => state.final_evaluation_calls,
        "final_evaluations" => Enum.map(state.final_evaluations, &dump_final_evaluation/1)
      }
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
          "payload" => %{"compatibility" => compatibility, "state" => state} = payload
        },
        expected_compatibility,
        runtime_program
      )
      when is_binary(payload_sha256) and is_map(compatibility) and
             is_map(expected_compatibility) and is_map(state) and is_struct(runtime_program) do
    unless checksum(payload) == payload_sha256 do
      raise ArgumentError, "SIMBA resume state checksum does not match its payload"
    end

    unless compatibility == expected_compatibility do
      raise ArgumentError,
            "SIMBA resume state does not match the program, datasets, or search configuration"
    end

    loaded = %{
      completed_steps: fetch_non_negative_integer!(state, "completed_steps"),
      population: state |> Map.fetch!("population") |> load_population!(runtime_program),
      winning_programs:
        state
        |> Map.fetch!("winning_programs")
        |> load_programs!(runtime_program, "winning_programs"),
      trial_logs: state |> Map.fetch!("trial_logs") |> load_list!("trial_logs"),
      order: state |> Map.fetch!("order") |> load_integer_list!("order"),
      cursor: fetch_non_negative_integer!(state, "cursor"),
      poisson_rng: state |> Map.fetch!("poisson_rng") |> Sampling.load!(),
      errors: state |> Map.fetch!("errors") |> load_list!("errors"),
      trajectory_calls: fetch_non_negative_integer!(state, "trajectory_calls"),
      candidate_evaluation_calls:
        fetch_non_negative_integer!(state, "candidate_evaluation_calls"),
      final_evaluation_calls: fetch_non_negative_integer!(state, "final_evaluation_calls"),
      final_evaluations:
        state
        |> Map.fetch!("final_evaluations")
        |> load_final_evaluations!(runtime_program)
    }

    validate_state!(loaded)
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid SIMBA resume state: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(value, _expected_compatibility, _runtime_program) do
    raise ArgumentError, "invalid SIMBA resume state: #{inspect(value)}"
  end

  defp dump_population(%Population{} = population) do
    %{
      "programs" =>
        Enum.map(population.program_ids, fn id ->
          %{"id" => id, "program" => population.programs |> Map.fetch!(id) |> dump_program()}
        end),
      "program_ids" => population.program_ids,
      "score_histories" =>
        Enum.map(population.program_ids, fn id ->
          %{"id" => id, "scores" => Map.fetch!(population.score_histories, id)}
        end),
      "next_id" => population.next_id,
      "policy" => SearchPolicy.dump(population.policy)
    }
  end

  defp load_population!(population, runtime_program) when is_map(population) do
    program_ids = population |> Map.fetch!("program_ids") |> load_integer_list!("program_ids")
    next_id = fetch_non_negative_integer!(population, "next_id")
    programs = load_id_records!(Map.fetch!(population, "programs"), "programs", program_ids)

    programs =
      Map.new(programs, fn {id, snapshot} ->
        {id, load_program!(snapshot, runtime_program)}
      end)

    score_histories =
      population
      |> Map.fetch!("score_histories")
      |> load_id_records!("score_histories", program_ids, "scores")

    unless Enum.all?(score_histories, fn {_id, scores} ->
             is_list(scores) and Enum.all?(scores, &is_number/1)
           end) do
      raise ArgumentError, "SIMBA checkpoint score_histories are invalid"
    end

    %Population{
      programs: programs,
      program_ids: program_ids,
      score_histories: Map.new(score_histories),
      next_id: next_id,
      policy: population |> Map.fetch!("policy") |> SearchPolicy.load!()
    }
  end

  defp load_population!(value, _runtime_program),
    do: raise(ArgumentError, "SIMBA checkpoint population must be a map, got: #{inspect(value)}")

  defp dump_program(program) do
    %{
      "predictors" =>
        Enum.map(DSEx.ProgramParameters.predictors(program), fn %{
                                                                  name: name,
                                                                  predictor: predictor
                                                                } ->
          %{
            "name" => Report.json_safe(name),
            "instruction" => predictor.signature.instructions,
            "demos" => Report.json_safe(predictor.demos)
          }
        end)
    }
  end

  defp load_program!(%{"predictors" => snapshots}, runtime_program) when is_list(snapshots) do
    runtime_predictors = DSEx.ProgramParameters.predictors(runtime_program)
    runtime_names = Enum.map(runtime_predictors, & &1.name)

    decoded =
      Enum.map(snapshots, fn
        %{"name" => name, "instruction" => instruction, "demos" => demos}
        when is_binary(instruction) and is_list(demos) ->
          %{name: Report.restore_json_safe(name), instruction: instruction, demos: demos}

        value ->
          raise ArgumentError,
                "SIMBA checkpoint contains an invalid predictor snapshot: #{inspect(value)}"
      end)

    unless Enum.map(decoded, & &1.name) == runtime_names do
      raise ArgumentError, "SIMBA checkpoint predictor names do not match the runtime program"
    end

    Enum.reduce(decoded, runtime_program, fn snapshot, program ->
      demos = Report.restore_json_safe(snapshot.demos)

      unless is_list(demos) do
        raise ArgumentError, "SIMBA checkpoint predictor demos must be a list"
      end

      program
      |> DSEx.ProgramParameters.put_instruction(snapshot.name, snapshot.instruction)
      |> DSEx.ProgramParameters.put_demos(snapshot.name, demos)
    end)
  end

  defp load_program!(value, _runtime_program),
    do:
      raise(
        ArgumentError,
        "SIMBA checkpoint contains an invalid program snapshot: #{inspect(value)}"
      )

  defp load_programs!(values, runtime_program, _name) when is_list(values),
    do: Enum.map(values, &load_program!(&1, runtime_program))

  defp load_programs!(value, _runtime_program, name),
    do: raise(ArgumentError, "SIMBA checkpoint #{name} must be a list, got: #{inspect(value)}")

  defp dump_final_evaluation(evaluation) do
    %{
      "finalist_index" => evaluation.finalist_index,
      "program" => dump_program(evaluation.program),
      "score" => evaluation.score,
      "scores" => evaluation.scores,
      "errors" => Report.json_safe(evaluation.errors)
    }
  end

  defp load_final_evaluations!(values, runtime_program) when is_list(values) do
    Enum.map(values, fn
      %{
        "finalist_index" => finalist_index,
        "program" => program,
        "score" => score,
        "scores" => scores,
        "errors" => errors
      }
      when is_integer(finalist_index) and finalist_index >= 0 and is_number(score) and
             is_list(scores) and is_list(errors) ->
        unless Enum.all?(scores, &is_number/1) do
          raise ArgumentError, "SIMBA checkpoint final evaluation scores are invalid"
        end

        %{
          finalist_index: finalist_index,
          program: load_program!(program, runtime_program),
          score: score,
          scores: scores,
          errors: Report.restore_json_safe(errors)
        }

      value ->
        raise ArgumentError,
              "SIMBA checkpoint contains an invalid final evaluation: #{inspect(value)}"
    end)
  end

  defp load_final_evaluations!(value, _runtime_program),
    do:
      raise(
        ArgumentError,
        "SIMBA checkpoint final_evaluations must be a list, got: #{inspect(value)}"
      )

  defp load_id_records!(records, name, expected_ids, value_key \\ "program")

  defp load_id_records!(records, name, expected_ids, value_key) when is_list(records) do
    loaded =
      Enum.map(records, fn
        %{"id" => id, ^value_key => value} when is_integer(id) and id >= 0 ->
          {id, value}

        value ->
          raise ArgumentError,
                "SIMBA checkpoint #{name} contains an invalid record: #{inspect(value)}"
      end)

    if Enum.map(loaded, &elem(&1, 0)) == expected_ids,
      do: loaded,
      else: raise(ArgumentError, "SIMBA checkpoint #{name} IDs are inconsistent")
  end

  defp load_id_records!(value, name, _expected_ids, _value_key),
    do: raise(ArgumentError, "SIMBA checkpoint #{name} must be a list, got: #{inspect(value)}")

  defp load_list!(value, _name) when is_list(value), do: Report.restore_json_safe(value)

  defp load_list!(value, name),
    do: raise(ArgumentError, "SIMBA checkpoint #{name} must be a list, got: #{inspect(value)}")

  defp load_integer_list!(values, name) when is_list(values) do
    if length(values) == length(Enum.uniq(values)) and
         Enum.all?(values, &(is_integer(&1) and &1 >= 0)) do
      values
    else
      raise ArgumentError,
            "SIMBA checkpoint #{name} must contain unique non-negative integers: #{inspect(values)}"
    end
  end

  defp load_integer_list!(value, name),
    do:
      raise(
        ArgumentError,
        "SIMBA checkpoint #{name} must contain unique non-negative integers: #{inspect(value)}"
      )

  defp fetch_non_negative_integer!(state, key) do
    case Map.fetch!(state, key) do
      value when is_integer(value) and value >= 0 -> value
      value -> raise ArgumentError, "SIMBA checkpoint #{key} is invalid: #{inspect(value)}"
    end
  end

  defp validate_state!(state) do
    expected_ids = Enum.to_list(0..(state.population.next_id - 1))

    unless state.population.next_id > 0 and state.population.program_ids == expected_ids do
      raise ArgumentError, "SIMBA checkpoint population IDs are not contiguous"
    end

    unless length(state.trial_logs) == state.completed_steps and
             Enum.map(state.trial_logs, &Map.get(&1, :step)) ==
               step_indices(state.completed_steps) do
      raise ArgumentError, "SIMBA checkpoint completed steps are not contiguous"
    end

    unless state.winning_programs != [] and
             length(state.winning_programs) <= state.completed_steps + 1 do
      raise ArgumentError, "SIMBA checkpoint winning programs are inconsistent"
    end

    unless Enum.map(state.final_evaluations, & &1.finalist_index) ==
             step_indices(length(state.final_evaluations), 0) do
      raise ArgumentError, "SIMBA checkpoint final evaluations are not contiguous"
    end

    state
  end

  defp step_indices(0), do: []
  defp step_indices(count), do: Enum.to_list(1..count)
  defp step_indices(0, _start), do: []
  defp step_indices(count, start), do: Enum.to_list(start..(start + count - 1))

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
