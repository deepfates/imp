defmodule DSEx.BenchmarkTruth.OptimizeAnything.CodeArtifact do
  @moduledoc false

  alias DSEx.Sandbox

  @max_source_bytes 2_000
  @max_ast_nodes 180
  @maximum_delay_ms 8_000

  @baseline "if retryable == false, do: -1, else: attempt * 500"

  @comparator """
  if(retryable == false,
    do: -1,
    else: if(retry_after_ms > 0,
      do: if(retry_after_ms > 8000, do: 8000, else: retry_after_ms),
      else: if(urgent == true and attempt <= 1,
        do: 0,
        else: if(attempt <= 0,
          do: 250 + jitter_slot * 25,
          else: if(attempt <= 1,
            do: 500 + jitter_slot * 25,
            else: if(attempt <= 2,
              do: 1000 + jitter_slot * 25,
              else: if(attempt <= 3,
                do: 2000 + jitter_slot * 25,
                else: 4000 + jitter_slot * 25
              )
            )
          )
        )
      )
    )
  )
  """

  def id, do: "optimize-anything-code-artifact-retry-controller-v1"

  def artifact_class, do: "code_artifact"

  def baseline, do: @baseline

  def comparator, do: @comparator

  def trainset do
    [
      example("train-non-retryable", 3, false, false, 0, 2, -1),
      example("train-server-hint", 2, true, false, 1_200, 1, 1_200),
      example("train-server-cap", 1, true, false, 12_000, 0, 8_000),
      example("train-urgent-first", 0, true, true, 0, 3, 0),
      example("train-backoff-zero", 0, true, false, 0, 0, 250),
      example("train-backoff-one", 1, true, false, 0, 2, 550),
      example("train-backoff-two", 2, true, false, 0, 1, 1_025),
      example("train-backoff-three", 3, true, false, 0, 3, 2_075)
    ]
  end

  def valset do
    [
      example("val-urgent-second", 1, true, true, 0, 0, 0),
      example("val-urgent-expired", 2, true, true, 0, 2, 1_050),
      example("val-hint-precedence", 0, true, true, 725, 3, 725),
      example("val-backoff-four", 4, true, false, 0, 3, 4_075),
      example("val-backoff-late", 8, true, false, 0, 1, 4_025),
      example("val-rejection-precedence", 0, false, true, 900, 0, -1)
    ]
  end

  def evaluate(candidate_text, example) when is_binary(candidate_text) and is_map(example) do
    with {:ok, source} <- validate_source(candidate_text),
         {:ok, actual} <- execute(source, example) do
      score_success(actual, example)
    else
      {:error, failure} -> score_failure(failure, example)
    end
  end

  def evaluate(_candidate_text, _example) do
    score_failure(
      diagnostic("invalid_candidate_type", "candidate_text must be a UTF-8 string", "input")
    )
  end

  def metadata do
    %{
      "artifact_format" => "single Elixir expression",
      "candidate_contract" => %{
        "available_variables" => [
          "attempt",
          "retryable",
          "urgent",
          "retry_after_ms",
          "jitter_slot"
        ],
        "allowed_syntax" =>
          "literals, the available variables, nested if/do/else, unary minus, and binary arithmetic, comparison, and boolean operators",
        "forbidden_syntax" =>
          "assignments, cond, case, guards, tuples, maps, modules, remote calls, and all function calls",
        "output" => "one integer from -1 through 8000",
        "requirement" =>
          "Return only the complete expression; use no helper bindings or functions."
      },
      "deterministic" => true,
      "execution_engine" => "DSEx.Sandbox AST interpreter",
      "objective" =>
        "Compute a retry delay in milliseconds with rejection, server-hint, urgency, backoff, and deterministic-jitter precedence.",
      "provenance" => %{
        "dataset" => "authored deterministic operational-policy cases",
        "implementation" => "DSEx benchmark truth suite",
        "version" => 1
      },
      "limits" => %{
        "arbitrary_host_execution" => false,
        "allowed_result" => "integer from -1 through 8000",
        "max_ast_nodes" => @max_ast_nodes,
        "max_source_bytes" => @max_source_bytes,
        "network_access" => false,
        "process_creation" => false
      },
      "scoring" => %{
        "bounded_output" => 0.05,
        "exact_result" => 0.65,
        "numeric_proximity" => 0.2,
        "result_type" => 0.1
      },
      "split" => %{"train_cases" => length(trainset()), "validation_cases" => length(valset())}
    }
  end

  defp example(id, attempt, retryable, urgent, retry_after_ms, jitter_slot, expected) do
    %{
      "id" => id,
      "inputs" => %{
        "attempt" => attempt,
        "jitter_slot" => jitter_slot,
        "retry_after_ms" => retry_after_ms,
        "retryable" => retryable,
        "urgent" => urgent
      },
      "expected" => expected
    }
  end

  defp validate_source(source) do
    cond do
      not String.valid?(source) ->
        {:error, diagnostic("parse_error", "candidate is not valid UTF-8", "parse")}

      byte_size(source) > @max_source_bytes ->
        {:error,
         diagnostic(
           "source_limit_exceeded",
           "candidate exceeds the #{@max_source_bytes}-byte source limit",
           "limits"
         )}

      String.trim(source) == "" ->
        {:error, diagnostic("empty_candidate", "candidate expression is empty", "parse")}

      true ->
        parse_and_measure(source)
    end
  end

  defp parse_and_measure(source) do
    case Code.string_to_quoted(source,
           static_atoms_encoder: fn value, _meta -> {:ok, to_string(value)} end
         ) do
      {:ok, ast} -> validate_ast_size(source, ast)
      {:error, detail} -> {:error, diagnostic("parse_error", inspect(detail), "parse")}
    end
  end

  defp validate_ast_size(source, ast) do
    {_ast, nodes} = Macro.prewalk(ast, 0, fn node, count -> {node, count + 1} end)

    if nodes <= @max_ast_nodes do
      {:ok, source}
    else
      {:error,
       diagnostic(
         "ast_limit_exceeded",
         "candidate has #{nodes} AST nodes; limit is #{@max_ast_nodes}",
         "limits"
       )}
    end
  end

  defp execute(source, %{"inputs" => inputs}) when is_map(inputs) do
    case Sandbox.eval(source, inputs) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, execution_diagnostic(reason)}
    end
  rescue
    exception ->
      {:error, diagnostic("runtime_error", Exception.message(exception), "interpretation")}
  catch
    kind, reason ->
      {:error, diagnostic("runtime_error", inspect({kind, reason}), "interpretation")}
  end

  defp execute(_source, _example) do
    {:error, diagnostic("invalid_example", "example must contain an inputs map", "evaluation")}
  end

  defp execution_diagnostic({:unsafe_ast, ast}) do
    diagnostic(
      "unsafe_ast",
      "expression uses syntax outside the bounded language: #{inspect(ast)}",
      "safety"
    )
  end

  defp execution_diagnostic({:unsafe_call, name, _args}) do
    diagnostic(
      "unsafe_call",
      "call is not available in the bounded language: #{inspect(name)}",
      "safety"
    )
  end

  defp execution_diagnostic(reason) do
    diagnostic("evaluation_error", inspect(reason), "interpretation")
  end

  defp score_success(actual, %{"expected" => expected, "id" => example_id}) do
    type_score = if is_integer(actual), do: 0.1, else: 0.0
    bounded_score = if valid_delay?(actual), do: 0.05, else: 0.0
    exact_score = if actual === expected, do: 0.65, else: 0.0
    proximity_score = proximity(actual, expected) * 0.2

    subscores = %{
      "bounded_output" => bounded_score,
      "exact_result" => exact_score,
      "numeric_proximity" => proximity_score,
      "result_type" => type_score
    }

    score = subscores |> Map.values() |> Enum.sum() |> min(1.0)

    {score,
     %{
       "actual" => json_safe(actual),
       "diagnostics" => success_diagnostics(actual, expected),
       "example_id" => example_id,
       "expected" => expected,
       "failure" => nil,
       "status" => if(actual === expected, do: "passed", else: "incorrect"),
       "subscores" => subscores
     }}
  end

  defp score_success(_actual, _example) do
    score_failure(
      diagnostic("invalid_example", "example lacks expected result or id", "evaluation")
    )
  end

  defp score_failure(failure, example \\ %{}) do
    {0.0,
     %{
       "actual" => nil,
       "diagnostics" => [failure],
       "example_id" => Map.get(example, "id"),
       "expected" => Map.get(example, "expected"),
       "failure" => failure,
       "status" => "failed",
       "subscores" => %{
         "bounded_output" => 0.0,
         "exact_result" => 0.0,
         "numeric_proximity" => 0.0,
         "result_type" => 0.0
       }
     }}
  end

  defp proximity(actual, expected) when is_integer(actual) and is_integer(expected) do
    denominator = max(abs(expected), 500)
    max(0.0, 1.0 - abs(actual - expected) / denominator)
  end

  defp proximity(_actual, _expected), do: 0.0

  defp valid_delay?(value), do: is_integer(value) and value >= -1 and value <= @maximum_delay_ms

  defp success_diagnostics(actual, expected) when actual === expected do
    [
      diagnostic(
        "exact_result",
        "candidate produced the expected retry decision",
        "evaluation",
        "info"
      )
    ]
  end

  defp success_diagnostics(actual, expected) do
    [
      diagnostic(
        "wrong_result",
        "expected #{inspect(expected)}, received #{inspect(actual)}",
        "evaluation"
      )
    ]
  end

  defp diagnostic(code, message, phase) do
    diagnostic(code, message, phase, "error")
  end

  defp diagnostic(code, message, phase, severity) do
    %{"code" => code, "message" => message, "phase" => phase, "severity" => severity}
  end

  defp json_safe(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: value

  defp json_safe(value), do: inspect(value)
end
