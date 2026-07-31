defmodule ImpDeployment.Banking77Pipeline do
  @moduledoc """
  Two-stage Banking77 intent router shared by the deployment examples.

  Stage one extracts evidence from the customer utterance. Stage two consumes
  that evidence and the original utterance to choose a typed route. Optimizers
  may update either named predictor through the public `Imp.Module` callbacks.
  """

  @behaviour Imp.Module

  defstruct [:analyze_intent, :classify_route]

  @default_routes ~w(R17 R42 R68 R93)
  @default_analysis "Summarize the banking request for routing."
  @default_routing "Choose exactly one opaque route code."

  def new(opts \\ []) when is_list(opts) do
    routes = Keyword.get(opts, :routes, @default_routes)
    analysis_instruction = Keyword.get(opts, :analysis_instruction, @default_analysis)
    routing_instruction = Keyword.get(opts, :routing_instruction, @default_routing)

    unless routes != [] and Enum.all?(routes, &is_binary/1) and
             length(routes) == length(Enum.uniq(routes)) do
      raise ArgumentError, "routes must be a non-empty list of unique strings"
    end

    %__MODULE__{
      analyze_intent:
        Imp.predict(
          Imp.signature("utterance -> evidence", analysis_instruction),
          adapter: Imp.Adapter.Chat,
          config: [cache: false, json_fallback: false]
        ),
      classify_route:
        Imp.predict(
          Imp.signature(
            "utterance, evidence -> route: enum[#{Enum.join(routes, ",")}]",
            routing_instruction
          ),
          adapter: Imp.Adapter.Chat,
          config: [cache: false, json_fallback: false]
        )
    }
  end

  @impl true
  def optimizer_predictors(program),
    do: [analyze_intent: program.analyze_intent, classify_route: program.classify_route]

  @impl true
  def update_optimizer_predictor(program, :analyze_intent, update),
    do: %{program | analyze_intent: update.(program.analyze_intent)}

  def update_optimizer_predictor(program, :classify_route, update),
    do: %{program | classify_route: update.(program.classify_route)}

  @impl true
  def call(program, inputs) do
    inputs = Map.new(inputs)
    utterance = Map.get(inputs, :utterance, Map.get(inputs, "utterance"))

    with true <- is_binary(utterance) || {:error, {:missing_input_fields, [:utterance]}},
         {:ok, analysis} <- Imp.call(program.analyze_intent, %{utterance: utterance}),
         evidence <- Imp.get(analysis, :evidence),
         {:ok, prediction} <-
           Imp.call(program.classify_route, %{utterance: utterance, evidence: evidence}) do
      {:ok, prediction}
    end
  end
end
