defmodule Imp.Optimizer.GEPA.Reflection do
  @moduledoc false

  alias Imp.Optimizer.GEPA.ComBee

  def execute(proposer, parent, context, %ComBee.Policy{} = combee_policy) do
    {status, replacements, reflection_calls, aggregation_reports} =
      Enum.reduce_while(context.components, {:ok, %{}, 0, []}, fn component,
                                                                  {:ok, replacements, calls,
                                                                   reports} ->
        records = Map.get(context.dataset, component, [])

        case ComBee.propose(
               proposer,
               parent.candidate,
               component,
               records,
               context.iteration,
               combee_policy
             ) do
          {:ok, text, observed, report} ->
            {:cont,
             {:ok, Map.put(replacements, component, text), calls + observed,
              append_report(reports, report)}}

          {:error, reason, observed, report} ->
            {:halt,
             {{:error, reason}, replacements, calls + observed, append_report(reports, report)}}
        end
      end)

    case status do
      :ok ->
        %{
          status: :ok,
          dataset: context.dataset,
          replacements: replacements,
          candidate: Map.merge(parent.candidate, replacements),
          reflection_calls: reflection_calls,
          aggregation_reports: aggregation_reports
        }

      {:error, reason} ->
        %{
          status: :error,
          dataset: context.dataset,
          replacements: replacements,
          error: reason,
          reflection_calls: reflection_calls,
          aggregation_reports: aggregation_reports
        }
    end
  end

  defp append_report(reports, nil), do: reports
  defp append_report(reports, report), do: reports ++ [report]
end
