defmodule DSEx.BenchmarkTruth.Papillon do
  @moduledoc false

  @behaviour DSEx.Module

  alias DSEx.Predict.{ChainOfThought, Predict}

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
           DSEx.Module.call(program.craft_redacted_request, %{user_query: user_query}),
         llm_request <- DSEx.Prediction.fetch!(craft_prediction, :llm_request),
         {:ok, raw_llm_response} <- call_untrusted_model(program.untrusted_model, llm_request),
         {:ok, llm_response} <- untrusted_response(raw_llm_response),
         {:ok, response_prediction} <-
           DSEx.Module.call(program.respond_to_query, %{
             related_llm_request: llm_request,
             related_llm_response: llm_response,
             user_query: user_query
           }),
         response <- DSEx.Prediction.fetch!(response_prediction, :response) do
      {:ok,
       DSEx.Prediction.new(
         llm_request: llm_request,
         llm_response: llm_response,
         response: response
       )}
    else
      _failure -> empty_prediction()
    end
  rescue
    _error -> empty_prediction()
  catch
    _kind, _reason -> empty_prediction()
  end

  def optimizer_predictors(%__MODULE__{} = program) do
    [
      craft_redacted_request: program.craft_redacted_request.predict,
      respond_to_query: program.respond_to_query
    ]
  end

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
    DSEx.Signature.new(
      %{inputs: [:user_query], outputs: [:llm_request]},
      String.trim(@craft_instructions)
    )
  end

  defp respond_signature do
    DSEx.Signature.new(
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
    DSEx.LM.generate(untrusted_model, [%{role: :user, content: llm_request}], [])
  end

  defp untrusted_response(response) when is_binary(response), do: {:ok, response}

  defp untrusted_response(%{
         __dsex_lm_output__: response,
         __dsex_lm_metadata__: _metadata
       })
       when is_binary(response),
       do: {:ok, response}

  defp untrusted_response(%{
         "__dsex_lm_output__" => response,
         "__dsex_lm_metadata__" => _metadata
       })
       when is_binary(response),
       do: {:ok, response}

  defp untrusted_response(_response), do: {:error, :invalid_untrusted_model_response}

  defp empty_prediction do
    {:ok, DSEx.Prediction.new(llm_request: "", llm_response: "", response: "")}
  end
end
