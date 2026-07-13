defmodule DSEx.BenchmarkTruth.IFBenchTwoStage do
  @moduledoc false

  @behaviour DSEx.Module

  defstruct [:generate_response_module, :ensure_correct_response_module]

  @generate_instruction "Respond to the query"
  @ensure_instruction "Ensure the response is correct and adheres to the given constraints. Your response will be used as the final response."

  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    %__MODULE__{
      generate_response_module:
        DSEx.chain_of_thought(
          DSEx.signature("query -> response", @generate_instruction),
          opts
        ),
      ensure_correct_response_module:
        DSEx.chain_of_thought(
          DSEx.signature("query, response -> final_response", @ensure_instruction),
          opts
        )
    }
  end

  def new(lm), do: new(lm, [])

  def new(lm, opts) when is_list(opts), do: new(Keyword.put(opts, :lm, lm))

  def optimizer_predictors(%__MODULE__{} = program) do
    [
      generate_response_module: program.generate_response_module.predict,
      ensure_correct_response_module: program.ensure_correct_response_module.predict
    ]
  end

  def update_optimizer_predictor(
        %__MODULE__{} = program,
        :generate_response_module,
        update
      )
      when is_function(update, 1) do
    update_in(program.generate_response_module.predict, update)
  end

  def update_optimizer_predictor(
        %__MODULE__{} = program,
        :ensure_correct_response_module,
        update
      )
      when is_function(update, 1) do
    update_in(program.ensure_correct_response_module.predict, update)
  end

  @impl true
  def call(%__MODULE__{} = program, inputs) when is_map(inputs) or is_list(inputs) do
    with {:ok, query} <- fetch_prompt(inputs),
         {:ok, response} <-
           DSEx.Module.call(program.generate_response_module, %{query: query}),
         {:ok, final_response} <-
           DSEx.Module.call(program.ensure_correct_response_module, %{
             query: query,
             response: DSEx.Prediction.fetch!(response, :response)
           }) do
      {:ok,
       DSEx.Prediction.new(
         [response: DSEx.Prediction.fetch!(final_response, :final_response)],
         metadata: final_response.metadata
       )}
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_ifbench_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  defp fetch_prompt(inputs) do
    inputs = Map.new(inputs)

    cond do
      Map.has_key?(inputs, :prompt) -> {:ok, Map.fetch!(inputs, :prompt)}
      Map.has_key?(inputs, "prompt") -> {:ok, Map.fetch!(inputs, "prompt")}
      Map.has_key?(inputs, :query) -> {:ok, Map.fetch!(inputs, :query)}
      Map.has_key?(inputs, "query") -> {:ok, Map.fetch!(inputs, "query")}
      true -> {:error, {:missing_input_fields, [:prompt]}}
    end
  rescue
    _error -> {:error, {:invalid_ifbench_inputs, "expected inputs as {key, value} pairs"}}
  end
end
