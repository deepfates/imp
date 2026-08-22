defmodule Imp.Module do
  @moduledoc """
  Behaviour and safe dispatcher for executable Imp programs.

  An Imp program is any struct whose module implements `call/2` and returns
  either `{:ok, %Imp.Prediction{}}` or `{:error, reason}`. `Imp.Module.call/2`
  is the central boundary used by evaluators, composition modules, streaming,
  optimizers, and the public `Imp.call/2` facade. It catches callback crashes
  and normalizes malformed callback returns so composed workflows can report
  failures without losing the rest of the run.

  Consumer-defined multi-stage programs may expose named predictors to every
  program optimizer by implementing the paired optional callbacks
  `optimizer_predictors/1` and `update_optimizer_predictor/3`. Both callbacks
  are required together. Predictor names must be unique atoms or strings and
  each value must be an `Imp.Predict.Predict` struct. The update callback must
  return the same program struct after applying the supplied function to the
  named predictor. `Imp.ProgramParameters` validates this contract before an
  optimizer can use it.

  Programs may additionally expose arbitrary data-only components with the
  paired `optimizer_components/1` and `update_optimizer_components/2`
  callbacks. Components carry descriptions, executable constraints, and
  dependency identities. The batch update callback must be pure and return the
  same program struct; Imp validates the complete change set before invoking it.
  """

  @type optimizer_predictor_name :: atom() | String.t()
  @type optimizer_predictor :: %Imp.Predict.Predict{}
  @type optimizer_predictor_entry ::
          {optimizer_predictor_name(), optimizer_predictor()}
          | %{name: optimizer_predictor_name(), predictor: optimizer_predictor()}

  @callback call(struct(), map() | keyword()) ::
              {:ok, Imp.Prediction.t()} | {:error, term()}

  @callback execute(struct(), map() | keyword(), Imp.Execution.t()) ::
              {:ok, Imp.Prediction.t()} | {:error, term()}

  @callback optimizer_predictors(struct()) :: [optimizer_predictor_entry()]

  @callback update_optimizer_predictor(
              struct(),
              optimizer_predictor_name(),
              (optimizer_predictor() -> optimizer_predictor())
            ) :: struct()

  @callback optimizer_components(struct()) :: [Imp.Optimizer.Component.t() | map()]

  @callback update_optimizer_components(
              struct(),
              %{required(String.t()) => Imp.Optimizer.Parameter.json_value()}
            ) :: struct()

  @optional_callbacks optimizer_predictors: 1,
                      update_optimizer_predictor: 3,
                      optimizer_components: 1,
                      update_optimizer_components: 2,
                      execute: 3

  @doc """
  Calls an Imp executable program and normalizes its result shape.

  Successful programs must return a `Imp.Prediction`:

      iex> lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
      iex> program = Imp.Predict.Predict.new("question -> answer", lm: lm)
      iex> {:ok, prediction} = Imp.Module.call(program, %{question: "2+2?"})
      iex> Imp.Prediction.get(prediction, :answer)
      "4"

  Non-program values are reported as not callable:

      iex> Imp.Module.call(%{}, %{question: "q"})
      {:error, {:not_callable, %{}}}

  """
  def call(%module{} = program, inputs) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 2) do
      safe_call(module, program, inputs)
    else
      {:error, {:not_callable, module}}
    end
  end

  def call(other, _inputs), do: {:error, {:not_callable, other}}

  @doc "Executes a program with explicit per-run capabilities when it supports them."
  def execute(%module{} = program, inputs, %Imp.Execution{} = execution) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :execute, 3) ->
        safe_dispatch(module, :execute, [program, inputs, execution])

      Imp.Execution.authorization_required?(execution) ->
        {:error, {:execution_capability_unsupported, module, :authorization}}

      true ->
        call(program, inputs)
    end
  end

  def execute(program, _inputs, execution),
    do: {:error, {:invalid_execution, program, execution}}

  defp safe_call(module, program, inputs) do
    safe_dispatch(module, :call, [program, inputs])
  end

  defp safe_dispatch(module, function, arguments) do
    Imp.Telemetry.span([:imp, :module], %{module: module}, fn ->
      case apply(module, function, arguments) do
        {:ok, %Imp.Prediction{} = prediction} ->
          {:ok, prediction}

        {:ok, other} ->
          {:error, {:invalid_module_prediction, module, inspect(other)}}

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:invalid_module_result, module, inspect(other)}}
      end
    end)
  rescue
    safety in Imp.OperationalSafetyError -> {:error, safety}
    error -> {:error, {:module_call_failed, module, error_message(error)}}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> {:error, safety}
        nil -> {:error, {:module_call_failed, module, error_message({kind, reason})}}
      end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
