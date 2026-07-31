defmodule Imp.BenchmarkTruth.Papillon do
  @moduledoc false

  @behaviour Imp.Module

  alias Imp.Predict.{ChainOfThought, Predict}

  @craft_instructions """
  Given a private user query, create a privacy-preserving request for a powerful external LLM.
  The LLM may assist without learning private information about the user.
  """

  @respond_instructions """
  Respond to a user query.
  For inspiration, we found a potentially related request to a powerful external LLM and its response.
  """

  defstruct [:craft_redacted_request, :respond_to_query, :untrusted_model]

  def new(untrusted_model, opts \\ []) do
    %__MODULE__{
      craft_redacted_request: ChainOfThought.new(craft_signature(), opts),
      respond_to_query: Predict.new(respond_signature(), opts),
      untrusted_model: untrusted_model
    }
  end

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    with {:ok, user_query} <- fetch_user_query(inputs),
         {:ok, craft_prediction} <-
           stage(:craft_redacted_request, fn ->
             Imp.Module.call(program.craft_redacted_request, %{user_query: user_query})
           end),
         {:ok, llm_request} <-
           prediction_field(:craft_redacted_request, craft_prediction, :llm_request),
         {:ok, raw_llm_response} <-
           stage(:untrusted_model, fn ->
             call_untrusted_model(program.untrusted_model, llm_request)
           end),
         {:ok, llm_response} <-
           stage(:untrusted_model, fn -> untrusted_response(raw_llm_response) end),
         {:ok, response_prediction} <-
           stage(:respond_to_query, fn ->
             Imp.Module.call(program.respond_to_query, %{
               related_llm_request: llm_request,
               related_llm_response: llm_response,
               user_query: user_query
             })
           end),
         {:ok, response} <- prediction_field(:respond_to_query, response_prediction, :response) do
      {:ok,
       Imp.Prediction.new(
         llm_request: llm_request,
         llm_response: llm_response,
         response: response
       )}
    else
      {:error, {:papillon_stage_failed, stage, reason}} -> empty_prediction(stage, reason)
      {:error, reason} -> empty_prediction(:input, reason)
    end
  rescue
    error ->
      Imp.OperationalSafetyError.raise_if_present!(error)
      empty_prediction(:papillon, error)
  catch
    kind, reason ->
      Imp.OperationalSafetyError.raise_if_present!({kind, reason})
      empty_prediction(:papillon, {kind, reason})
  end

  @impl true
  def optimizer_predictors(%__MODULE__{} = program) do
    [
      craft_redacted_request: program.craft_redacted_request.predict,
      respond_to_query: program.respond_to_query
    ]
  end

  @impl true
  def update_optimizer_predictor(%__MODULE__{} = program, :craft_redacted_request, update) do
    %{
      program
      | craft_redacted_request: %{
          program.craft_redacted_request
          | predict: update.(program.craft_redacted_request.predict)
        }
    }
  end

  def update_optimizer_predictor(%__MODULE__{} = program, :respond_to_query, update) do
    %{program | respond_to_query: update.(program.respond_to_query)}
  end

  defp craft_signature do
    Imp.Signature.new(
      %{inputs: [:user_query], outputs: [:llm_request]},
      String.trim(@craft_instructions)
    )
  end

  defp respond_signature do
    Imp.Signature.new(
      %{
        inputs: [
          :related_llm_request,
          %{
            name: :related_llm_response,
            desc: "information from a powerful LLM responding to a related request"
          },
          %{name: :user_query, desc: "the user's request you need to fulfill"}
        ],
        outputs: [
          %{name: :response, desc: "your final response to the user's request"}
        ]
      },
      String.trim(@respond_instructions)
    )
  end

  defp fetch_user_query(inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)

    cond do
      Map.has_key?(inputs, :user_query) -> {:ok, Map.fetch!(inputs, :user_query)}
      Map.has_key?(inputs, "user_query") -> {:ok, Map.fetch!(inputs, "user_query")}
      true -> {:error, {:missing_input_fields, [:user_query]}}
    end
  rescue
    _error -> {:error, :invalid_inputs}
  end

  defp fetch_user_query(_inputs), do: {:error, :invalid_inputs}

  defp call_untrusted_model(untrusted_model, llm_request) do
    Imp.LM.generate(untrusted_model, [%{role: :user, content: llm_request}], [])
  end

  defp untrusted_response(response) do
    case Imp.LM.Result.output(response) do
      {:ok, output} when is_binary(output) -> {:ok, output}
      {:ok, _output} -> {:error, :invalid_untrusted_model_response}
      {:error, _reason} = error -> error
    end
  end

  defp stage(name, fun) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        Imp.OperationalSafetyError.raise_if_present!(reason)
        {:error, {:papillon_stage_failed, name, reason}}

      other ->
        {:error, {:papillon_stage_failed, name, {:invalid_stage_result, other}}}
    end
  rescue
    error ->
      Imp.OperationalSafetyError.raise_if_present!(error)
      {:error, {:papillon_stage_failed, name, error}}
  catch
    kind, reason ->
      Imp.OperationalSafetyError.raise_if_present!({kind, reason})
      {:error, {:papillon_stage_failed, name, {kind, reason}}}
  end

  defp prediction_field(stage, prediction, field) do
    case Imp.Prediction.get(prediction, field) do
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:papillon_stage_failed, stage, {:invalid_output, field, value}}}
    end
  end

  defp empty_prediction(stage, reason) do
    diagnostic = %{
      stage: stage,
      reason: Imp.Redaction.redact(reason)
    }

    {:ok,
     Imp.Prediction.new(
       %{llm_request: "", llm_response: "", response: ""},
       metadata: %{papillon_failure: diagnostic}
     )}
  end
end
