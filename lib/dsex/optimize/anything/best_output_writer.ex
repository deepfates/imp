defmodule DSEx.Optimize.Anything.BestOutputWriter do
  @moduledoc false

  @behaviour DSEx.Optimizer.GEPA.Callback

  alias DSEx.Optimizer.Report

  @enforce_keys [:run_dir, :store]
  defstruct [:run_dir, :store, track_best_outputs: false]

  @type t :: %__MODULE__{
          run_dir: Path.t(),
          store: pid(),
          track_best_outputs: boolean()
        }

  @spec open(Path.t(), boolean()) :: {DSEx.Optimizer.GEPA.Callback.callback(), t()}
  def open(run_dir, track_best_outputs)
      when is_binary(run_dir) and is_boolean(track_best_outputs) do
    {:ok, store} = Agent.start(fn -> %{} end)

    context = %__MODULE__{
      run_dir: run_dir,
      store: store,
      track_best_outputs: track_best_outputs
    }

    {{__MODULE__, context}, context}
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{store: store}) do
    if Process.alive?(store), do: Agent.stop(store, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def on_valset_evaluated(%{outputs_by_val_id: nil}, _context), do: :ok

  def on_valset_evaluated(event, %__MODULE__{} = context) do
    writes =
      Agent.get_and_update(context.store, fn best_scores ->
        collect_writes(event, context.track_best_outputs, best_scores)
      end)

    Enum.each(writes, &write_output!(context.run_dir, event, &1))
    :ok
  end

  defp collect_writes(event, track_best_outputs, best_scores) do
    event.scores_by_val_id
    |> Enum.sort_by(fn {validation_id, _score} -> inspect(validation_id) end)
    |> Enum.reduce({[], best_scores}, fn {validation_id, score}, {writes, scores} ->
      previous = Map.get(scores, validation_id)
      seed? = event.iteration == 0
      improved? = is_nil(previous) or score > previous
      write? = seed? or (track_best_outputs and improved?)
      scores = if improved?, do: Map.put(scores, validation_id, score), else: scores

      if write?,
        do:
          {[{validation_id, score, Map.fetch!(event.outputs_by_val_id, validation_id)} | writes],
           scores},
        else: {writes, scores}
    end)
    |> then(fn {writes, scores} -> {Enum.reverse(writes), scores} end)
  end

  defp write_output!(run_dir, event, {validation_id, score, output}) do
    directory =
      Path.join([
        run_dir,
        "generated_best_outputs_valset",
        "task_#{task_id(validation_id)}"
      ])

    File.mkdir_p!(directory)

    path =
      Path.join(
        directory,
        "iter_#{event.iteration}_prog_#{event.candidate_idx}.json"
      )

    payload =
      %{
        schema_version: 1,
        validation_id: validation_id,
        candidate_idx: event.candidate_idx,
        iteration: event.iteration,
        score: score,
        output: output
      }
      |> Report.json_safe()
      |> Jason.encode!(pretty: true)

    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, payload)
    File.rename!(temporary, path)
  end

  defp task_id(id) when is_integer(id) and id >= 0, do: Integer.to_string(id)

  defp task_id(id) do
    id
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end
