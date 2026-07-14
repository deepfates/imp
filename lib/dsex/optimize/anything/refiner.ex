defmodule DSEx.Optimize.Anything.Refiner do
  @moduledoc false

  alias DSEx.Optimize.Anything

  @refiner_component :refiner_prompt
  @failure_score -1.0e9
  @known_options [
    :candidate,
    :evaluator,
    :example,
    :max_refinements,
    :on_evaluation,
    :refiner_lm,
    :refiner_prompt,
    :refiner_prompt_component
  ]

  defmodule Result do
    @moduledoc false

    @enforce_keys [:score, :asi, :output, :candidate, :attempts]
    defstruct [:score, :asi, :output, :candidate, :attempts]

    @type t :: %__MODULE__{
            score: number(),
            asi: map(),
            output: term(),
            candidate: map(),
            attempts: [map()]
          }
  end

  @type evaluator_result ::
          number()
          | {number(), map()}
          | {number(), term(), map()}
          | map()

  @type evaluator :: (map(), term() -> evaluator_result()) | (map() -> evaluator_result())

  @doc """
  Evaluates and optionally refines one explicit named candidate.

  Required options are `:refiner_lm`, `:refiner_prompt`, `:max_refinements`,
  `:candidate`, `:example`, and `:evaluator`. `:refiner_prompt_component`
  defaults to `:refiner_prompt` and identifies the candidate parameter that is
  instructions for the refiner rather than part of the JSON proposal.
  """
  @spec execute(keyword()) :: Result.t()
  def execute(opts) when is_list(opts) do
    validate_options!(opts)

    candidate = Keyword.fetch!(opts, :candidate)
    component = Keyword.get(opts, :refiner_prompt_component, @refiner_component)
    prompt = resolve_refiner_prompt!(Keyword.fetch!(opts, :refiner_prompt), component, candidate)

    execute_validated(
      Keyword.fetch!(opts, :refiner_lm),
      prompt,
      Keyword.fetch!(opts, :max_refinements),
      candidate,
      Keyword.fetch!(opts, :example),
      Keyword.fetch!(opts, :evaluator),
      component,
      Keyword.get(opts, :on_evaluation, fn _evaluation -> :ok end)
    )
  end

  def execute(opts) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.execute/1 expects keyword options, got: #{inspect(opts)}"
  end

  @doc "Convenience form using the conventional `:refiner_prompt` component name."
  @spec execute(term(), String.t(), non_neg_integer(), map(), term(), evaluator()) :: Result.t()
  def execute(refiner_lm, refiner_prompt, max_refinements, candidate, example, evaluator) do
    execute(
      refiner_lm: refiner_lm,
      refiner_prompt: refiner_prompt,
      max_refinements: max_refinements,
      candidate: candidate,
      example: example,
      evaluator: evaluator
    )
  end

  defp execute_validated(
         refiner_lm,
         refiner_prompt,
         max_refinements,
         candidate,
         example,
         evaluator,
         component,
         on_evaluation
       ) do
    validate_lm!(refiner_lm)
    validate_max_refinements!(max_refinements)
    validate_candidate!(candidate, component)
    validate_evaluator!(evaluator)
    validate_on_evaluation!(on_evaluation)

    params = drop_component(candidate, component)
    original = evaluate_original!(evaluator, candidate, example)
    notify_evaluation(on_evaluation, candidate, original)
    original_attempt = successful_attempt(0, params, original)

    state = %{
      best: Map.put(original, :candidate, candidate),
      current_params: params,
      attempts: [original_attempt]
    }

    context = %{
      lm: refiner_lm,
      prompt: refiner_prompt,
      candidate: candidate,
      example: example,
      evaluator: evaluator,
      component: component,
      on_evaluation: on_evaluation
    }

    state = refine(state, max_refinements, context)

    attempts = state.attempts
    asi = attach_attempts(original.asi, state.best.asi, attempts)

    %Result{
      score: state.best.score,
      asi: asi,
      output: state.best.output,
      candidate: state.best.candidate,
      attempts: attempts
    }
  end

  defp refine(state, 0, _context), do: state

  defp refine(state, max_refinements, context) do
    Enum.reduce_while(1..max_refinements, state, &refinement_step(&1, &2, context))
  end

  defp refinement_step(iteration, state, context) do
    case propose(context.lm, context.prompt, state.current_params, state.attempts) do
      {:ok, proposed_params} ->
        evaluate_proposal(iteration, state, proposed_params, context)

      {:error, error, raw_output} ->
        attempt = failed_attempt(iteration, error, raw_output)
        {:cont, append_attempt(state, attempt)}

      {:runtime_error, error} ->
        attempt = failed_attempt(iteration, "runtime error: #{error}")
        {:halt, append_attempt(state, attempt)}
    end
  end

  defp evaluate_proposal(iteration, state, proposed_params, context) do
    refined_candidate = put_params(context.candidate, proposed_params, context.component)

    case evaluate_refinement(context.evaluator, refined_candidate, context.example) do
      {:ok, evaluation} ->
        notify_evaluation(context.on_evaluation, refined_candidate, evaluation)

        handle_evaluated_proposal(
          iteration,
          state,
          proposed_params,
          refined_candidate,
          evaluation
        )

      {:error, error} ->
        attempt = failed_attempt(iteration, "runtime error: #{error}")
        {:halt, append_attempt(state, attempt)}
    end
  end

  defp handle_evaluated_proposal(iteration, state, params, candidate, evaluation) do
    attempt = successful_attempt(iteration, params, evaluation)
    next = append_attempt(state, attempt)

    if evaluation.score > state.best.score do
      best = Map.put(evaluation, :candidate, candidate)
      {:cont, %{next | best: best, current_params: params}}
    else
      {:halt, next}
    end
  end

  defp propose(lm, refiner_prompt, current_params, attempts) do
    messages = [%{role: :user, content: refiner_prompt(refiner_prompt, current_params, attempts)}]

    case lm |> DSEx.LM.generate(messages, []) |> DSEx.LM.Result.unwrap() do
      {:ok, output} -> parse_proposal(output, current_params)
      {:error, reason} -> {:runtime_error, redact_error(reason)}
    end
  rescue
    error -> {:runtime_error, redact_error(error)}
  catch
    kind, reason -> {:runtime_error, redact_error({kind, reason})}
  end

  defp parse_proposal(output, current_params) when is_binary(output) do
    raw_output = strip_fences(output)

    case Jason.decode(raw_output) do
      {:ok, parsed} -> validate_proposal(parsed, current_params, raw_output)
      {:error, error} -> {:error, "JSON parse error: #{redact_error(error)}", raw_output}
    end
  end

  defp parse_proposal(%DSEx.Prediction{} = prediction, current_params) do
    prediction
    |> DSEx.Prediction.to_map()
    |> parse_proposal(current_params)
  end

  defp parse_proposal(output, current_params) when is_map(output) do
    case validate_proposal(output, current_params, nil) do
      {:ok, _proposal} = success ->
        success

      {:error, _error, _raw} = shape_error ->
        case embedded_output(output) do
          nil -> shape_error
          embedded -> parse_proposal(embedded, current_params)
        end
    end
  end

  defp parse_proposal(output, _current_params) do
    {:error, "JSON shape error: expected an object response", inspect(output)}
  end

  defp validate_proposal(parsed, current_params, raw_output) when is_map(parsed) do
    expected = Map.new(current_params, fn {key, _value} -> {to_string(key), key} end)
    actual = Map.new(parsed, fn {key, value} -> {to_string(key), value} end)

    cond do
      map_size(actual) != map_size(parsed) ->
        shape_error("candidate parameter names are ambiguous", raw_output)

      MapSet.new(Map.keys(actual)) != MapSet.new(Map.keys(expected)) ->
        shape_error(
          "expected exactly these candidate parameters: #{inspect(Enum.sort(Map.keys(expected)))}",
          raw_output
        )

      not Enum.all?(actual, fn {_key, value} -> is_binary(value) end) ->
        shape_error("all candidate parameter values must be strings", raw_output)

      true ->
        proposal = Map.new(actual, fn {name, value} -> {Map.fetch!(expected, name), value} end)
        {:ok, proposal}
    end
  end

  defp validate_proposal(_parsed, _current_params, raw_output) do
    shape_error("expected a JSON object", raw_output)
  end

  defp shape_error(message, raw_output),
    do: {:error, "JSON shape error: #{message}", raw_output}

  defp evaluate_original!(evaluator, candidate, example) do
    evaluator
    |> call_evaluator(candidate, example)
    |> normalize_evaluation!()
  rescue
    error ->
      raise RuntimeError,
            "Optimize Anything refiner evaluator failed: #{redact_error(error)}"
  catch
    kind, reason ->
      raise RuntimeError,
            "Optimize Anything refiner evaluator failed: #{redact_error({kind, reason})}"
  end

  defp evaluate_refinement(evaluator, candidate, example) do
    evaluation = evaluator |> call_evaluator(candidate, example) |> normalize_evaluation!()
    {:ok, evaluation}
  rescue
    error -> {:error, redact_error(error)}
  catch
    kind, reason -> {:error, redact_error({kind, reason})}
  end

  defp call_evaluator(evaluator, candidate, example) when is_function(evaluator, 2),
    do: evaluator.(candidate, example)

  defp call_evaluator(evaluator, candidate, _example) when is_function(evaluator, 1),
    do: evaluator.(candidate)

  defp normalize_evaluation!(score) when is_number(score),
    do: %{score: score, output: nil, asi: %{}}

  defp normalize_evaluation!({score, asi}) when is_number(score) and is_map(asi),
    do: %{score: score, output: nil, asi: DSEx.Redaction.redact(asi)}

  defp normalize_evaluation!({score, output, asi}) when is_number(score) and is_map(asi),
    do: %{score: score, output: DSEx.Redaction.redact(output), asi: DSEx.Redaction.redact(asi)}

  defp normalize_evaluation!(%Anything.Evaluation{} = evaluation) do
    normalize_evaluation!({
      evaluation.score,
      nil,
      %{"diagnostics" => evaluation.diagnostics, "metadata" => evaluation.metadata}
    })
  end

  defp normalize_evaluation!(evaluation) when is_map(evaluation) do
    score = fetch_value(evaluation, :score)
    output = fetch_value(evaluation, :output)

    asi =
      fetch_value(
        evaluation,
        :side_info,
        fetch_value(evaluation, :asi, drop_normalized_fields(evaluation))
      )

    normalize_evaluation!({score, output, asi})
  end

  defp normalize_evaluation!(result) do
    raise ArgumentError,
          "refiner evaluator must return a numeric score, {score, asi}, " <>
            "{score, output, asi}, or an evaluation-like map; got: #{inspect(result)}"
  end

  defp successful_attempt(iteration, candidate, evaluation) do
    %{
      "iteration" => iteration,
      "candidate" => DSEx.Redaction.redact(candidate),
      "score" => evaluation.score,
      "side_info" => evaluation.asi
    }
  end

  defp failed_attempt(iteration, error, raw_output \\ nil) do
    %{"iteration" => iteration, "error" => redact_error(error), "score" => @failure_score}
    |> maybe_put_raw_output(raw_output)
  end

  defp maybe_put_raw_output(attempt, nil), do: attempt

  defp maybe_put_raw_output(attempt, raw_output) do
    Map.put(
      attempt,
      "raw_output",
      raw_output |> to_string() |> String.slice(0, 2_000) |> DSEx.Redaction.redact()
    )
  end

  defp append_attempt(state, attempt), do: %{state | attempts: state.attempts ++ [attempt]}

  defp attach_attempts(original_asi, best_asi, attempts) do
    refiner_info = %{"Attempts" => attempts}

    refiner_info =
      case {fetch_value(original_asi, :scores), fetch_value(best_asi, :scores)} do
        {original_scores, best_scores} when is_map(original_scores) and is_map(best_scores) ->
          Map.put(refiner_info, "scores", best_scores)

        {original_scores, _best_scores} when is_map(original_scores) ->
          Map.put(refiner_info, "scores", %{})

        _other ->
          refiner_info
      end

    Map.put(original_asi, "refiner_prompt_specific_info", refiner_info)
  end

  defp refiner_prompt(instructions, current_params, attempts) do
    """
    You are refining a candidate to improve its performance.

    ## Instructions
    #{instructions}

    ## Current Candidate (JSON)
    ```json
    #{Jason.encode!(json_safe(current_params), pretty: true)}
    ```

    ## Evaluation History
    The following shows all evaluation attempts so far, including scores and feedback:
    ```json
    #{Jason.encode!(json_safe(attempts), pretty: true)}
    ```

    ## Task
    Analyze the evaluation history and propose an improved version of the candidate.
    Return ONLY a valid JSON object containing every candidate parameter shown above
    (no explanation, no markdown fences).
    """
  end

  defp json_safe(value) when is_struct(value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe(nil), do: nil
  defp json_safe(value), do: inspect(value)

  defp strip_fences(output) do
    output = String.trim(output)

    case Regex.run(~r/\A```(?:json)?\s*\n?(.*?)\n?```\s*\z/is, output, capture: :all_but_first) do
      [json] -> String.trim(json)
      nil -> output
    end
  end

  defp embedded_output(output) do
    Enum.find_value(
      [:output, "output", :content, "content", :answer, "answer", :json, "json"],
      fn key ->
        case Map.get(output, key) do
          value when is_binary(value) -> value
          _other -> nil
        end
      end
    )
  end

  defp put_params(candidate, params, component) do
    refiner_entry = Enum.find(candidate, fn {key, _value} -> same_key?(key, component) end)
    Map.new([refiner_entry | Map.to_list(params)])
  end

  defp drop_component(candidate, component) do
    Map.reject(candidate, fn {key, _value} -> same_key?(key, component) end)
  end

  defp resolve_refiner_prompt!(prompt, component, _candidate) when is_binary(prompt) do
    if same_key?(prompt, component) do
      raise ArgumentError,
            "refiner_prompt must contain instructions, not the component name; " <>
              "pass the component with :refiner_prompt_component"
    end

    prompt
  end

  defp resolve_refiner_prompt!(component, component, candidate)
       when is_atom(component) or is_binary(component) do
    fetch_component!(candidate, component)
  end

  defp resolve_refiner_prompt!(prompt, _component, _candidate) do
    raise ArgumentError, "refiner_prompt must be a string, got: #{inspect(prompt)}"
  end

  defp fetch_component!(candidate, component) when is_map(candidate) do
    case Enum.find(candidate, fn {key, _value} -> same_key?(key, component) end) do
      {_key, prompt} when is_binary(prompt) ->
        prompt

      {_key, prompt} ->
        raise ArgumentError, "refiner prompt component must be text, got: #{inspect(prompt)}"

      nil ->
        raise ArgumentError, "candidate is missing refiner prompt component #{inspect(component)}"
    end
  end

  defp fetch_component!(candidate, _component) do
    raise ArgumentError, "candidate must be an explicit named map, got: #{inspect(candidate)}"
  end

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{inspect(__MODULE__)}.execute/1 expects keyword options"
    end

    unknown = Keyword.keys(opts) -- @known_options

    if unknown != [] do
      raise ArgumentError, "unknown refiner options: #{inspect(unknown)}"
    end

    missing =
      Enum.reject(
        [:refiner_lm, :refiner_prompt, :max_refinements, :candidate, :example, :evaluator],
        &Keyword.has_key?(opts, &1)
      )

    if missing != [] do
      raise ArgumentError, "missing required refiner options: #{inspect(missing)}"
    end
  end

  defp validate_lm!(lm) do
    case DSEx.LM.validate_lm(lm) do
      {:ok, _lm} -> :ok
      {:error, reason} -> raise ArgumentError, "invalid refiner LM: #{reason}"
    end
  end

  defp validate_max_refinements!(count) when is_integer(count) and count >= 0, do: :ok

  defp validate_max_refinements!(count) do
    raise ArgumentError, "max_refinements must be a non-negative integer, got: #{inspect(count)}"
  end

  defp validate_candidate!(candidate, component)
       when is_map(candidate) and map_size(candidate) > 1 do
    keys = Map.keys(candidate)

    cond do
      not Enum.all?(keys, &(is_atom(&1) or is_binary(&1))) ->
        raise ArgumentError, "candidate parameter names must be atoms or strings"

      duplicate_string_names?(keys) ->
        raise ArgumentError, "candidate parameter names must be unique when converted to strings"

      not Enum.all?(candidate, fn {_key, value} -> is_binary(value) end) ->
        raise ArgumentError, "candidate parameter values must all be strings"

      Enum.count(candidate, fn {key, _value} -> same_key?(key, component) end) != 1 ->
        raise ArgumentError, "candidate must contain exactly one refiner prompt component"

      true ->
        :ok
    end
  end

  defp validate_candidate!(candidate, _component) do
    raise ArgumentError,
          "candidate must be an explicit named map containing a refiner prompt and at least one optimizable parameter, got: #{inspect(candidate)}"
  end

  defp duplicate_string_names?(keys) do
    names = Enum.map(keys, &to_string/1)
    length(names) != MapSet.size(MapSet.new(names))
  end

  defp validate_evaluator!(evaluator)
       when is_function(evaluator, 1) or is_function(evaluator, 2),
       do: :ok

  defp validate_evaluator!(evaluator) do
    raise ArgumentError,
          "evaluator must be an arity-1 or arity-2 function, got: #{inspect(evaluator)}"
  end

  defp validate_on_evaluation!(callback) when is_function(callback, 1), do: :ok

  defp validate_on_evaluation!(callback) do
    raise ArgumentError,
          "on_evaluation must be an arity-1 function, got: #{inspect(callback)}"
  end

  defp notify_evaluation(callback, candidate, evaluation) do
    callback.(%{candidate: candidate, score: evaluation.score, asi: evaluation.asi})
    :ok
  end

  defp drop_normalized_fields(evaluation) do
    Map.drop(evaluation, [
      :score,
      "score",
      :output,
      "output",
      :side_info,
      "side_info",
      :asi,
      "asi"
    ])
  end

  defp fetch_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp same_key?(left, right), do: to_string(left) == to_string(right)

  defp redact_error(%{__exception__: true} = exception) do
    exception |> Exception.message() |> DSEx.Redaction.redact()
  end

  defp redact_error(reason) when is_binary(reason), do: DSEx.Redaction.redact(reason)
  defp redact_error(reason), do: reason |> inspect() |> DSEx.Redaction.redact()
end
