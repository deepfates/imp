defmodule Imp.BenchmarkTruth.CampaignBudget do
  @moduledoc false

  defdelegate start_link(opts), to: Imp.Optimizer.Budget
  defdelegate reserve(server, messages, opts), to: Imp.Optimizer.Budget
  defdelegate release(server, reservation), to: Imp.Optimizer.Budget
  defdelegate record_usage(server, usage), to: Imp.Optimizer.Budget
  defdelegate authorize_transport_attempt(server), to: Imp.Optimizer.Budget
  defdelegate snapshot(server), to: Imp.Optimizer.Budget
  defdelegate validate_pricing_source_url!(url), to: Imp.Optimizer.Budget
  defdelegate evidence_digest(value), to: Imp.Optimizer.Budget
  defdelegate attach_req_llm(server, opts \\ []), to: Imp.Optimizer.Budget

  defdelegate handle_req_llm_usage_event(event, measurements, metadata, config),
    to: Imp.Optimizer.Budget
end

defmodule Imp.BenchmarkTruth.BudgetedLM do
  @moduledoc false
  @behaviour Imp.LM

  defstruct [:inner, :budget, :max_output_tokens]

  @impl true
  def generate(%__MODULE__{} = lm, messages, opts) do
    lm
    |> Map.from_struct()
    |> Map.put(:record_usage, false)
    |> then(&struct!(Imp.LM.Budgeted, &1))
    |> Imp.LM.Budgeted.generate(messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end
