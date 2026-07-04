defmodule DSPy.Streaming do
  @moduledoc "Enumerable-friendly streaming helpers."

  def stream(program, inputs, opts \\ []) do
    case Keyword.get(opts, :chunker) do
      nil ->
        Stream.resource(
          fn -> call_once(program, inputs) end,
          fn
            {:done, _} -> {:halt, nil}
            {:ok, text} -> {String.graphemes(text), {:done, text}}
            {:error, reason} -> {[{:error, reason}], {:done, nil}}
          end,
          fn _ -> :ok end
        )

      chunker when is_function(chunker, 1) ->
        program
        |> call_once(inputs)
        |> case do
          {:ok, text} -> chunker.(text)
          {:error, reason} -> [{:error, reason}]
        end
        |> Stream.map(& &1)
    end
  end

  def collect(program, inputs, opts \\ []) do
    program
    |> stream(inputs, opts)
    |> Enum.reject(&match?({:error, _}, &1))
    |> Enum.join()
  end

  defp call_once(program, inputs) do
    case program.__struct__.call(program, inputs) do
      {:ok, prediction} ->
        {:ok, prediction |> DSPy.Prediction.to_map() |> Map.values() |> Enum.join("")}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
