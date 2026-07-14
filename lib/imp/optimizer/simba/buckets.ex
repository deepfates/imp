defmodule Imp.Optimizer.SIMBA.Buckets do
  @moduledoc false

  alias Imp.Optimizer.Sampling

  @enforce_keys [:example, :trajectories, :max_score, :min_score, :average_score, :rank]
  defstruct [:example, :trajectories, :max_score, :min_score, :average_score, :rank]

  @type trajectory :: map()
  @type t :: %__MODULE__{
          example: term(),
          trajectories: [trajectory()],
          max_score: number(),
          min_score: number(),
          average_score: float(),
          rank: {number(), number(), float()}
        }

  @type analysis :: %{
          buckets: [t()],
          batch_10th_percentile_score: float(),
          batch_90th_percentile_score: float()
        }

  @spec analyze([trajectory()]) :: analysis()
  def analyze(trajectories) when is_list(trajectories) do
    %{
      buckets: rank(trajectories),
      batch_10th_percentile_score: percentile(trajectories, 10),
      batch_90th_percentile_score: percentile(trajectories, 90)
    }
  end

  @doc """
  Groups trajectories by example and ranks the resulting buckets.

  Both atom and string keys are accepted for `example` and `score`. Examples
  retain first-seen order when rank tuples tie.
  """
  @spec rank([trajectory()]) :: [t()]
  def rank(trajectories) when is_list(trajectories) do
    trajectories
    |> group_by_example()
    |> Enum.map(fn {example, bucket} -> build_bucket(example, bucket) end)
    |> Enum.sort_by(& &1.rank, :desc)
  end

  @doc """
  Ranks model-major outputs using DSPy's strided mini-batch grouping.

  This form is useful before wrapped outputs have had their example field
  attached: output indices `i`, `i + batch_size`, ... belong to one example.
  """
  @spec rank([trajectory()], pos_integer()) :: [t()]
  def rank(outputs, batch_size)
      when is_list(outputs) and is_integer(batch_size) and batch_size > 0 do
    if rem(length(outputs), batch_size) != 0 do
      raise ArgumentError, "trajectory count must be divisible by batch size"
    end

    outputs
    |> strided_buckets(batch_size)
    |> Enum.with_index()
    |> Enum.map(fn {bucket, example_index} -> build_bucket(example_index, bucket) end)
    |> Enum.sort_by(& &1.rank, :desc)
  end

  @spec batch_percentiles([trajectory()]) :: {float(), float()}
  def batch_percentiles(trajectories) when is_list(trajectories) do
    {percentile(trajectories, 10), percentile(trajectories, 90)}
  end

  @spec score(trajectory()) :: number()
  def score(%{score: score}) when is_number(score), do: score
  def score(%{"score" => score}) when is_number(score), do: score

  def score(trajectory) do
    raise ArgumentError, "trajectory has no numeric score: #{inspect(trajectory)}"
  end

  defp group_by_example(trajectories) do
    {order, grouped} =
      Enum.reduce(trajectories, {[], %{}}, fn trajectory, {order, grouped} ->
        example = example(trajectory)

        if Map.has_key?(grouped, example) do
          {order, Map.update!(grouped, example, &(&1 ++ [trajectory]))}
        else
          {order ++ [example], Map.put(grouped, example, [trajectory])}
        end
      end)

    Enum.map(order, &{&1, Map.fetch!(grouped, &1)})
  end

  defp example(%{example: example}), do: example
  defp example(%{"example" => example}), do: example

  defp example(trajectory) do
    raise ArgumentError, "trajectory has no example: #{inspect(trajectory)}"
  end

  defp build_bucket(_example, []) do
    raise ArgumentError, "cannot build an empty trajectory bucket"
  end

  defp build_bucket(example, trajectories) do
    trajectories = Enum.sort_by(trajectories, &score/1, :desc)
    scores = Enum.map(trajectories, &score/1)
    max_score = hd(scores)
    min_score = List.last(scores)
    average_score = Enum.sum(scores) / length(scores)

    %__MODULE__{
      example: example,
      trajectories: trajectories,
      max_score: max_score,
      min_score: min_score,
      average_score: average_score,
      rank: {max_score - min_score, max_score, max_score - average_score}
    }
  end

  defp percentile(trajectories, percentile) do
    trajectories
    |> Enum.map(&score/1)
    |> Sampling.percentile(percentile)
  end

  defp strided_buckets(outputs, batch_size) do
    for offset <- 0..(batch_size - 1) do
      outputs
      |> Enum.drop(offset)
      |> Enum.take_every(batch_size)
    end
  end
end
