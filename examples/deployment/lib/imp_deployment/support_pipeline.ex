defmodule ImpDeployment.SupportPipeline do
  @moduledoc """
  Trusted application-owned two-stage support router.

  The analysis predictor turns a ticket into typed intermediate evidence. The
  routing predictor consumes both the original ticket and that evidence to
  produce validated team and urgency outputs.
  """

  @behaviour Imp.Module

  defstruct [:analyze, :route]

  def new do
    %__MODULE__{
      analyze:
        Imp.predict(
          Imp.signature(
            "ticket -> analysis: string",
            "Extract the operational signal needed to route this support ticket."
          )
        ),
      route:
        Imp.predict(
          Imp.signature(
            "ticket, analysis -> team: enum[atlas,harbor,beacon,quill], urgency: enum[normal,high]",
            "Use the original ticket and the analysis to select the owning opaque team and urgency."
          )
        )
    }
  end

  @impl true
  def optimizer_predictors(%__MODULE__{} = program) do
    [analyze: program.analyze, route: program.route]
  end

  @impl true
  def update_optimizer_predictor(%__MODULE__{} = program, :analyze, update),
    do: %{program | analyze: update.(program.analyze)}

  def update_optimizer_predictor(%__MODULE__{} = program, :route, update),
    do: %{program | route: update.(program.route)}

  @impl true
  def call(%__MODULE__{} = program, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)
    ticket = Map.get(inputs, :ticket, Map.get(inputs, "ticket"))

    if is_binary(ticket) do
      with {:ok, analysis_prediction} <- Imp.call(program.analyze, %{ticket: ticket}),
           analysis <- Imp.Prediction.fetch!(analysis_prediction, :analysis),
           {:ok, routing_prediction} <-
             Imp.call(program.route, %{ticket: ticket, analysis: analysis}) do
        {:ok,
         %{
           routing_prediction
           | metadata:
               Map.put(routing_prediction.metadata, :support_pipeline, %{
                 analysis: analysis,
                 stages: [:analyze, :route]
               })
         }}
      end
    else
      {:error, {:missing_input_fields, [:ticket]}}
    end
  end

  def call(%__MODULE__{}, inputs), do: {:error, {:invalid_support_pipeline_inputs, inputs}}
end
