defmodule Imp.Predict.RLM.Session do
  @moduledoc false

  use GenServer

  @type snapshot :: %{
          vars: map(),
          contexts: map(),
          context_count: non_neg_integer(),
          histories: list(),
          history_count: non_neg_integer(),
          compaction_history: list()
        }

  def start_link, do: GenServer.start_link(__MODULE__, %{})

  def close(pid) when is_pid(pid) do
    :global.trans(lock(pid), fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end
      else
        :ok
      end
    end)
  end

  def transaction(pid, fun) when is_pid(pid) and is_function(fun, 1) do
    :global.trans(lock(pid), fn ->
      with {:ok, snapshot} <- session_call(pid, :snapshot) do
        case fun.(snapshot) do
          {result, %{vars: vars} = next} when is_map(vars) ->
            case session_call(pid, {:commit, next}) do
              {:ok, :ok} -> result
              {:error, :closed} -> {:error, :rlm_persistent_session_closed}
            end

          result ->
            result
        end
      else
        {:error, :closed} -> {:error, :rlm_persistent_session_closed}
      end
    end)
  end

  def merge_inputs(
        %{vars: vars, contexts: contexts, context_count: context_count} = state,
        inputs
      )
      when is_map(inputs) do
    vars = restore_histories(vars, state)

    {vars, contexts, context_count} =
      Enum.reduce(inputs, {vars, contexts, context_count}, fn {key, value},
                                                              {vars, contexts, context_count} ->
        if to_string(key) == "context" do
          root_context = Map.get(contexts, :context, value)

          vars =
            vars
            |> Map.put(:context, root_context)
            |> Map.put("context_#{context_count}", value)

          {vars, Map.put(contexts, :context, root_context), context_count + 1}
        else
          {Map.put(vars, key, value), contexts, context_count}
        end
      end)

    %{state | vars: vars, contexts: contexts, context_count: context_count}
  end

  def add_history(
        %{histories: histories} = state,
        message_history,
        compaction_history,
        compaction?
      )
      when is_list(message_history) and is_list(compaction_history) do
    histories = histories ++ [message_history]

    state = %{
      state
      | histories: histories,
        history_count: length(histories),
        compaction_history: compaction_history
    }

    %{state | vars: restore_histories(state.vars, state, compaction?)}
  end

  def protected_vars(%{contexts: contexts} = state, compaction?) do
    %{}
    |> maybe_put_protected("context", Map.fetch(contexts, :context))
    |> maybe_put_protected("history", history_alias(state, compaction?))
  end

  @impl true
  def init(_state) do
    {:ok,
     %{
       vars: %{},
       contexts: %{},
       context_count: 0,
       histories: [],
       history_count: 0,
       compaction_history: []
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:commit, next}, _from, _state) do
    {:reply, :ok, next}
  end

  defp restore_histories(vars, state, compaction? \\ false) do
    vars =
      state.histories
      |> Enum.with_index()
      |> Enum.reduce(vars, fn {history, index}, vars ->
        Map.put(vars, "history_#{index}", history)
      end)

    case history_alias(state, compaction?) do
      {:ok, history} -> Map.put(vars, :history, history)
      :error -> vars |> Map.delete(:history) |> Map.delete("history")
    end
  end

  defp history_alias(state, true), do: {:ok, state.compaction_history}
  defp history_alias(%{histories: [history | _rest]}, false), do: {:ok, history}
  defp history_alias(_state, false), do: :error

  defp maybe_put_protected(vars, _name, :error), do: vars
  defp maybe_put_protected(vars, name, {:ok, value}), do: Map.put(vars, name, value)

  defp session_call(pid, message) do
    {:ok, GenServer.call(pid, message)}
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp lock(pid), do: {{__MODULE__, pid}, self()}
end
