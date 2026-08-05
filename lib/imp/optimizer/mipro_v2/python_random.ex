defmodule Imp.Optimizer.MIPROv2.PythonRandom do
  @moduledoc false

  import Bitwise

  @n 624
  @m 397
  @matrix_a 0x9908B0DF
  @upper_mask 0x80000000
  @lower_mask 0x7FFFFFFF
  @word_mask 0xFFFFFFFF

  defstruct [:state, :index]

  @algorithm "python_random_mt19937"

  @spec new(non_neg_integer()) :: %__MODULE__{}
  def new(seed) when is_integer(seed) and seed >= 0 do
    words = seed_words(seed)
    state = init_genrand(19_650_218)
    state = init_by_array(state, words)
    %__MODULE__{state: List.to_tuple(state), index: @n}
  end

  @doc false
  @spec dump(%__MODULE__{}) :: map()
  def dump(%__MODULE__{state: state, index: index})
      when is_tuple(state) and tuple_size(state) == @n and is_integer(index) and index >= 0 and
             index <= @n do
    %{
      "algorithm" => @algorithm,
      "state" => Tuple.to_list(state),
      "index" => index
    }
  end

  @doc false
  @spec load!(map()) :: %__MODULE__{}
  def load!(%{"algorithm" => @algorithm, "state" => state, "index" => index} = checkpoint)
      when is_list(state) and length(state) == @n and is_integer(index) and index >= 0 and
             index <= @n and map_size(checkpoint) == 3 do
    unless Enum.all?(state, &(is_integer(&1) and &1 >= 0 and &1 <= @word_mask)) do
      raise ArgumentError, "invalid Python random checkpoint state"
    end

    %__MODULE__{state: List.to_tuple(state), index: index}
  end

  def load!(value),
    do: raise(ArgumentError, "invalid Python random checkpoint: #{inspect(value)}")

  @spec choice(%__MODULE__{}, nonempty_list(term())) :: {term(), %__MODULE__{}}
  def choice(%__MODULE__{} = rng, values) when is_list(values) and values != [] do
    {index, rng} = randbelow(rng, length(values))
    {Enum.at(values, index), rng}
  end

  @spec randint(%__MODULE__{}, integer(), integer()) :: {integer(), %__MODULE__{}}
  def randint(%__MODULE__{} = rng, lower, upper)
      when is_integer(lower) and is_integer(upper) and lower <= upper do
    {offset, rng} = randbelow(rng, upper - lower + 1)
    {lower + offset, rng}
  end

  @doc false
  @spec random(%__MODULE__{}) :: {float(), %__MODULE__{}}
  def random(%__MODULE__{} = rng) do
    {first, rng} = next_word(rng)
    {second, rng} = next_word(rng)
    value = ((first >>> 5) * 67_108_864 + (second >>> 6)) / 9_007_199_254_740_992
    {value, rng}
  end

  @spec shuffle(%__MODULE__{}, list(term())) :: {list(term()), %__MODULE__{}}
  def shuffle(%__MODULE__{} = rng, values) when length(values) < 2, do: {values, rng}

  def shuffle(%__MODULE__{} = rng, values) when is_list(values) do
    array = :array.from_list(values)

    {array, rng} =
      Enum.reduce((length(values) - 1)..1//-1, {array, rng}, fn index, {array, rng} ->
        {selected, rng} = randbelow(rng, index + 1)
        left = :array.get(index, array)
        right = :array.get(selected, array)

        array =
          array |> then(&:array.set(index, right, &1)) |> then(&:array.set(selected, left, &1))

        {array, rng}
      end)

    {:array.to_list(array), rng}
  end

  @spec sample(%__MODULE__{}, list(term()), non_neg_integer()) :: {list(term()), %__MODULE__{}}
  def sample(%__MODULE__{} = rng, values, count)
      when is_list(values) and is_integer(count) and count >= 0 and count <= length(values) do
    population_size = length(values)

    set_size =
      if count > 5, do: 21 + Integer.pow(4, ceil(:math.log(count * 3) / :math.log(4))), else: 21

    if population_size <= set_size do
      sample_from_pool(rng, :array.from_list(values), population_size, count, [])
    else
      sample_from_indices(rng, values, population_size, count, MapSet.new(), [])
    end
  end

  def sample(%__MODULE__{}, values, count) when is_list(values) and is_integer(count) do
    raise ArgumentError,
          "sample count must be between zero and the population size (#{length(values)}), got: #{count}"
  end

  defp sample_from_pool(rng, _pool, _population_size, 0, result),
    do: {Enum.reverse(result), rng}

  defp sample_from_pool(rng, pool, population_size, remaining, result) do
    selected_count = length(result)
    {index, rng} = randbelow(rng, population_size - selected_count)
    value = :array.get(index, pool)
    last = :array.get(population_size - selected_count - 1, pool)
    pool = :array.set(index, last, pool)
    sample_from_pool(rng, pool, population_size, remaining - 1, [value | result])
  end

  defp sample_from_indices(rng, _values, _population_size, 0, _selected, result),
    do: {Enum.reverse(result), rng}

  defp sample_from_indices(rng, values, population_size, remaining, selected, result) do
    {index, rng} = unique_index(rng, population_size, selected)

    sample_from_indices(
      rng,
      values,
      population_size,
      remaining - 1,
      MapSet.put(selected, index),
      [Enum.fetch!(values, index) | result]
    )
  end

  defp unique_index(rng, population_size, selected) do
    {index, rng} = randbelow(rng, population_size)

    if MapSet.member?(selected, index),
      do: unique_index(rng, population_size, selected),
      else: {index, rng}
  end

  defp randbelow(rng, n) when n > 0 do
    bits = bit_length(n)
    {value, rng} = getrandbits(rng, bits)
    if value < n, do: {value, rng}, else: randbelow(rng, n)
  end

  defp getrandbits(rng, bits) when bits > 0 and bits <= 32 do
    {word, rng} = next_word(rng)
    {word >>> (32 - bits), rng}
  end

  defp next_word(%__MODULE__{index: index} = rng) when index >= @n do
    next_word(%{rng | state: twist(rng.state), index: 0})
  end

  defp next_word(%__MODULE__{state: state, index: index} = rng) do
    y = elem(state, index)
    y = bxor(y, y >>> 11)
    y = bxor(y, y <<< 7 &&& 0x9D2C5680)
    y = bxor(y, y <<< 15 &&& 0xEFC60000)
    y = bxor(y, y >>> 18) &&& @word_mask
    {y, %{rng | index: index + 1}}
  end

  defp twist(state) do
    0..(@n - 1)
    |> Enum.map(fn index ->
      y =
        (elem(state, index) &&& @upper_mask) ||| (elem(state, rem(index + 1, @n)) &&& @lower_mask)

      value = bxor(elem(state, rem(index + @m, @n)), y >>> 1)
      if (y &&& 1) == 1, do: bxor(value, @matrix_a), else: value
    end)
    |> List.to_tuple()
  end

  defp seed_words(0), do: [0]
  defp seed_words(seed), do: do_seed_words(seed, [])
  defp do_seed_words(0, words), do: Enum.reverse(words)
  defp do_seed_words(seed, words), do: do_seed_words(seed >>> 32, [seed &&& @word_mask | words])

  defp init_genrand(seed) do
    Enum.reduce(1..(@n - 1), [seed &&& @word_mask], fn index, reversed ->
      previous = hd(reversed)
      value = 1_812_433_253 * bxor(previous, previous >>> 30) + index &&& @word_mask
      [value | reversed]
    end)
    |> Enum.reverse()
  end

  # CPython's integer seeding delegates to the reference MT init_by_array
  # routine with little-endian 32-bit words from abs(seed).
  defp init_by_array(initial, keys) do
    array = :array.from_list(initial)
    key_count = length(keys)
    iterations = max(@n, key_count)

    {array, i, _j} =
      Enum.reduce(1..iterations, {array, 1, 0}, fn _step, {array, i, j} ->
        previous = :array.get(i - 1, array)
        value = :array.get(i, array)
        mixed = bxor(value, bxor(previous, previous >>> 30) * 1_664_525)
        value = mixed + Enum.at(keys, j) + j &&& @word_mask
        array = :array.set(i, value, array)
        i = i + 1
        j = j + 1

        if i >= @n do
          {:array.set(0, :array.get(@n - 1, array), array), 1, rem(j, key_count)}
        else
          {array, i, rem(j, key_count)}
        end
      end)

    {array, _i} =
      Enum.reduce(1..(@n - 1), {array, i}, fn _step, {array, i} ->
        previous = :array.get(i - 1, array)
        value = :array.get(i, array)
        mixed = bxor(value, bxor(previous, previous >>> 30) * 1_566_083_941)
        value = mixed - i &&& @word_mask
        array = :array.set(i, value, array)
        i = i + 1

        if i >= @n,
          do: {:array.set(0, :array.get(@n - 1, array), array), 1},
          else: {array, i}
      end)

    array |> then(&:array.set(0, 0x80000000, &1)) |> :array.to_list()
  end

  defp bit_length(value), do: value |> Integer.digits(2) |> length()
end
