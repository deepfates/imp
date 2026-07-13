defmodule DSEx.Optimizer.GEPA.Reflection do
  @moduledoc false

  alias DSEx.Optimizer.GEPA.Adapter

  def execute(adapter, proposer, parent, context) do
    dataset =
      Adapter.make_reflective_dataset(
        adapter,
        parent.candidate,
        context.parent_result,
        context.components
      )

    {status, replacements, reflection_calls} =
      Enum.reduce_while(context.components, {:ok, %{}, 0}, fn component,
                                                              {:ok, replacements, calls} ->
        case propose(proposer, parent.candidate, component, dataset, context.iteration) do
          {:ok, text} -> {:cont, {:ok, Map.put(replacements, component, text), calls + 1}}
          {:error, reason} -> {:halt, {{:error, reason}, replacements, calls + 1}}
        end
      end)

    case status do
      :ok ->
        %{
          status: :ok,
          dataset: dataset,
          replacements: replacements,
          candidate: Map.merge(parent.candidate, replacements),
          reflection_calls: reflection_calls
        }

      {:error, reason} ->
        %{
          status: :error,
          dataset: dataset,
          replacements: replacements,
          error: reason,
          reflection_calls: reflection_calls
        }
    end
  end

  defp propose(proposer, candidate, component, dataset, iteration) do
    records = Map.get(dataset, component, [])

    case proposer.(candidate, component, records, iteration) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      text when is_binary(text) -> {:ok, text}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_proposal, other}}
    end
  rescue
    error -> {:error, {:proposal_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:proposal_throw, kind, reason}}
  end
end
