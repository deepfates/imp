defmodule Imp.Optimizer.MIPROv2.NumpyRandomState do
  @moduledoc false

  import Bitwise

  @n 624
  @m 397
  @matrix_a 0x9908B0DF
  @upper_mask 0x80000000
  @lower_mask 0x7FFFFFFF
  @word_mask 0xFFFFFFFF

  defstruct [:state, :index]

  @spec new(0..0xFFFFFFFF) :: %__MODULE__{}
  def new(seed) when is_integer(seed) and seed >= 0 and seed <= @word_mask do
    state =
      Enum.reduce(1..(@n - 1), [seed], fn index, reversed ->
        previous = hd(reversed)
        word = 1_812_433_253 * bxor(previous, previous >>> 30) + index &&& @word_mask
        [word | reversed]
      end)
      |> Enum.reverse()
      |> List.to_tuple()

    %__MODULE__{state: state, index: @n}
  end

  def new(seed) do
    raise ArgumentError,
          "NumPy RandomState seed must be an integer in 0..4294967295, got: #{inspect(seed)}"
  end

  @doc false
  @spec categorical(%__MODULE__{}, nonempty_list(term())) :: {term(), %__MODULE__{}}
  def categorical(%__MODULE__{} = rng, [_ | _] = choices) do
    {rated, rng} =
      Enum.map_reduce(choices, rng, fn choice, rng ->
        {rating, rng} = uniform_double(rng)
        {{choice, rating}, rng}
      end)

    # NumPy's argmax keeps the first maximum.
    {choice, _rating} = Enum.max_by(rated, &elem(&1, 1))
    {choice, rng}
  end

  @doc false
  @spec uniforms(%__MODULE__{}, non_neg_integer()) :: {[float()], %__MODULE__{}}
  def uniforms(%__MODULE__{} = rng, count) when is_integer(count) and count >= 0 do
    Enum.map_reduce(1..count//1, rng, fn _, rng -> uniform_double(rng) end)
  end

  @doc false
  @spec weighted_indices(%__MODULE__{}, [number()], non_neg_integer()) ::
          {[non_neg_integer()], %__MODULE__{}}
  def weighted_indices(%__MODULE__{} = rng, weights, count)
      when is_list(weights) and weights != [] and is_integer(count) and count >= 0 do
    total = Enum.sum(weights)

    unless Enum.all?(weights, &(is_number(&1) and &1 >= 0)) and total > 0 do
      raise ArgumentError, "weighted choice requires non-negative weights with positive mass"
    end

    normalized = Enum.map(weights, &(&1 / total))
    cumulative = Enum.scan(normalized, &+/2)

    Enum.map_reduce(1..count//1, rng, fn _, rng ->
      {quantile, rng} = uniform_double(rng)
      index = Enum.count(cumulative, &(&1 < quantile))
      {min(index, length(weights) - 1), rng}
    end)
  end

  @doc false
  def dump(%__MODULE__{state: state, index: index}) do
    %{
      "algorithm" => "numpy_random_state_mt19937",
      "words" => Tuple.to_list(state),
      "index" => index
    }
  end

  @doc false
  def load!(
        %{
          "algorithm" => "numpy_random_state_mt19937",
          "words" => words,
          "index" => index
        } = checkpoint
      )
      when is_list(words) and length(words) == @n and is_integer(index) and index >= 0 and
             index <= @n and map_size(checkpoint) == 3 do
    unless Enum.all?(words, &(is_integer(&1) and &1 >= 0 and &1 <= @word_mask)) do
      raise ArgumentError, "NumPy RandomState checkpoint contains invalid words"
    end

    %__MODULE__{state: List.to_tuple(words), index: index}
  end

  def load!(value),
    do: raise(ArgumentError, "invalid NumPy RandomState checkpoint: #{inspect(value)}")

  defp uniform_double(rng) do
    {first, rng} = next_word(rng)
    {second, rng} = next_word(rng)
    numerator = (first >>> 5) * 67_108_864.0 + (second >>> 6)
    {numerator / 9_007_199_254_740_992.0, rng}
  end

  defp next_word(%__MODULE__{index: index} = rng) when index >= @n do
    next_word(%{rng | state: twist(rng.state), index: 0})
  end

  defp next_word(%__MODULE__{state: state, index: index} = rng) do
    value = elem(state, index)
    value = bxor(value, value >>> 11)
    value = bxor(value, value <<< 7 &&& 0x9D2C5680)
    value = bxor(value, value <<< 15 &&& 0xEFC60000)
    value = bxor(value, value >>> 18) &&& @word_mask
    {value, %{rng | index: index + 1}}
  end

  defp twist(state) do
    0..(@n - 1)
    |> Enum.map(fn index ->
      value =
        (elem(state, index) &&& @upper_mask) |||
          (elem(state, rem(index + 1, @n)) &&& @lower_mask)

      word = bxor(elem(state, rem(index + @m, @n)), value >>> 1)
      if (value &&& 1) == 1, do: bxor(word, @matrix_a), else: word
    end)
    |> List.to_tuple()
  end
end
