defmodule Imp.TestSupport.TwoStageOptimizerProgram do
  @moduledoc false

  @behaviour Imp.Module

  defstruct [:analyze_intent, :classify_route]

  def new(lm, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Imp.Adapter.Chat)

    %__MODULE__{
      analyze_intent:
        Imp.predict(
          Imp.signature("utterance -> evidence", "Summarize the customer's intent."),
          lm: lm,
          adapter: adapter
        ),
      classify_route:
        Imp.predict(
          Imp.signature(
            "utterance, evidence -> route: enum[R17,R42,R68,R93]",
            "Choose the matching opaque route code."
          ),
          lm: lm,
          adapter: adapter
        )
    }
  end

  def optimizer_predictors(%__MODULE__{} = program) do
    [
      analyze_intent: program.analyze_intent,
      classify_route: program.classify_route
    ]
  end

  def update_optimizer_predictor(%__MODULE__{} = program, :analyze_intent, update),
    do: %{program | analyze_intent: update.(program.analyze_intent)}

  def update_optimizer_predictor(%__MODULE__{} = program, :classify_route, update),
    do: %{program | classify_route: update.(program.classify_route)}

  @impl true
  def call(%__MODULE__{} = program, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)
    utterance = Map.get(inputs, :utterance, Map.get(inputs, "utterance"))

    if is_binary(utterance) do
      with {:ok, analysis} <- Imp.call(program.analyze_intent, %{utterance: utterance}),
           evidence <- Imp.Prediction.fetch!(analysis, :evidence),
           {:ok, classification} <-
             Imp.call(program.classify_route, %{utterance: utterance, evidence: evidence}) do
        {:ok, classification}
      end
    else
      {:error, {:missing_input_fields, [:utterance]}}
    end
  end

  def call(%__MODULE__{}, inputs),
    do: {:error, {:invalid_two_stage_inputs, inputs}}
end
