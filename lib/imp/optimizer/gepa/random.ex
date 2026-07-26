defmodule Imp.Optimizer.GEPA.Random do
  @moduledoc false

  alias Imp.Optimizer.MIPROv2.PythonRandom

  @python_algorithm "python_mt19937"

  @type state :: :rand.state() | struct()

  @spec new(non_neg_integer(), :beam_native | :python_v3) :: state()
  def new(seed, :beam_native), do: :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3})
  def new(seed, :python_v3), do: PythonRandom.new(seed)

  @spec integer(pos_integer(), state()) :: {non_neg_integer(), state()}
  def integer(count, %PythonRandom{} = state) when count > 0 do
    {value, state} = PythonRandom.randint(state, 0, count - 1)
    {value, state}
  end

  def integer(count, state) when count > 0 do
    {value, state} = :rand.uniform_s(count, state)
    {value - 1, state}
  end

  @spec shuffle(list(), state()) :: {list(), state()}
  def shuffle(values, %PythonRandom{} = state), do: PythonRandom.shuffle(state, values)

  def shuffle(values, state) when is_list(values) do
    values
    |> Enum.map_reduce(state, fn value, state ->
      {key, state} = :rand.uniform_s(state)
      {{key, value}, state}
    end)
    |> then(fn {decorated, state} ->
      {decorated |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), state}
    end)
  end

  @spec valid?(term()) :: boolean()
  def valid?(%PythonRandom{state: state, index: index}) do
    is_tuple(state) and tuple_size(state) == 624 and is_integer(index) and index in 0..624 and
      state |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 0xFFFFFFFF))
  end

  def valid?(state) do
    :rand.export_seed_s(state)
    true
  rescue
    _error -> false
  end

  @spec dump(state()) :: map()
  def dump(%PythonRandom{} = state) do
    unless valid?(state), do: raise(ArgumentError, "invalid Python-compatible GEPA RNG state")

    %{
      "algorithm" => @python_algorithm,
      "index" => state.index,
      "words" => Tuple.to_list(state.state)
    }
  end

  def dump(state) do
    {:exsss, [first | second]} = :rand.export_seed_s(state)
    %{"algorithm" => "exsss", "words" => [first, second]}
  end

  @spec load!(map()) :: state()
  def load!(%{"algorithm" => "exsss", "words" => [first, second]})
      when is_integer(first) and is_integer(second),
      do: :rand.seed_s({:exsss, [first | second]})

  def load!(%{"algorithm" => @python_algorithm, "index" => index, "words" => words})
      when is_integer(index) and is_list(words) do
    state = %PythonRandom{state: List.to_tuple(words), index: index}

    if valid?(state),
      do: state,
      else: raise(ArgumentError, "invalid Python-compatible GEPA RNG state")
  end

  def load!(value), do: raise(ArgumentError, "invalid GEPA RNG state: #{inspect(value)}")
end
