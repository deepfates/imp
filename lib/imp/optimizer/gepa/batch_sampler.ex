defmodule Imp.Optimizer.GEPA.BatchSampler do
  @moduledoc false

  defstruct minibatch_size: nil,
            trainset_identity: nil,
            shuffled_ids: [],
            epoch: -1,
            id_freqs: %{},
            last_trainset_size: 0,
            current_iteration: nil,
            calls_in_iteration: 0

  @type t :: %__MODULE__{
          minibatch_size: pos_integer() | nil,
          trainset_identity: String.t() | nil,
          shuffled_ids: [non_neg_integer()],
          epoch: integer(),
          id_freqs: %{optional(non_neg_integer()) => pos_integer()},
          last_trainset_size: non_neg_integer(),
          current_iteration: non_neg_integer() | nil,
          calls_in_iteration: non_neg_integer()
        }

  @spec new(pos_integer() | nil) :: t()
  def new(minibatch_size \\ nil)
  def new(nil), do: %__MODULE__{}

  def new(minibatch_size) when is_integer(minibatch_size) and minibatch_size > 0,
    do: %__MODULE__{minibatch_size: minibatch_size}

  def new(minibatch_size) do
    raise ArgumentError,
          "GEPA batch sampler minibatch size must be a positive integer, got: #{inspect(minibatch_size)}"
  end

  @doc false
  @spec bind_size!(t(), pos_integer()) :: t()
  def bind_size!(%__MODULE__{minibatch_size: nil} = sampler, size)
      when is_integer(size) and size > 0,
      do: %{sampler | minibatch_size: size}

  def bind_size!(%__MODULE__{minibatch_size: size} = sampler, size)
      when is_integer(size) and size > 0,
      do: sampler

  def bind_size!(%__MODULE__{minibatch_size: stored}, requested)
      when is_integer(requested) and requested > 0 do
    raise ArgumentError,
          "GEPA resume minibatch size mismatch: stored #{inspect(stored)}, requested #{requested}"
  end

  @doc false
  @spec bind!(t(), pos_integer(), [term()]) :: t()
  def bind!(%__MODULE__{} = sampler, size, trainset) when is_list(trainset) do
    sampler
    |> bind_size!(size)
    |> bind_trainset!(trainset)
  end

  @doc false
  @spec bind_trainset!(t(), [term()]) :: t()
  def bind_trainset!(%__MODULE__{} = sampler, trainset) when is_list(trainset) do
    requested = trainset_identity(trainset)

    case sampler.trainset_identity do
      nil ->
        %{sampler | trainset_identity: requested}

      ^requested ->
        sampler

      stored ->
        raise ArgumentError,
              "GEPA resume trainset identity mismatch: stored #{stored}, requested #{requested}"
    end
  end

  @doc false
  @spec reconfigure!(t(), pos_integer(), [term()]) :: t()
  def reconfigure!(%__MODULE__{} = sampler, size, trainset)
      when is_integer(size) and size > 0 and is_list(trainset) do
    sampler = bind_trainset!(sampler, trainset)

    if sampler.minibatch_size in [nil, size] do
      bind_size!(sampler, size)
    else
      %__MODULE__{
        minibatch_size: size,
        trainset_identity: sampler.trainset_identity
      }
    end
  end

  @spec next_batches(
          t(),
          [term()],
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          :rand.state()
        ) ::
          {[{[term()], [non_neg_integer()]}], t(), :rand.state()}
  def next_batches(%__MODULE__{} = sampler, trainset, size, count, iteration, rng_state)
      when is_list(trainset) and trainset != [] and is_integer(size) and size > 0 and
             is_integer(count) and count > 0 and is_integer(iteration) and iteration >= 0 do
    sampler = bind!(sampler, size, trainset)

    {batches, {sampler, rng_state}} =
      Enum.map_reduce(1..count, {sampler, rng_state}, fn _call, {sampler, rng_state} ->
        {ids, sampler, rng_state} =
          next_ids(sampler, length(trainset), size, iteration, rng_state)

        {{Enum.map(ids, &Enum.fetch!(trainset, &1)), ids}, {sampler, rng_state}}
      end)

    {batches, sampler, rng_state}
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = sampler) do
    %{
      "minibatch_size" => sampler.minibatch_size,
      "trainset_identity" => sampler.trainset_identity,
      "shuffled_ids" => sampler.shuffled_ids,
      "epoch" => sampler.epoch,
      "id_freqs" =>
        Map.new(sampler.id_freqs, fn {id, count} -> {Integer.to_string(id), count} end),
      "last_trainset_size" => sampler.last_trainset_size,
      "current_iteration" => sampler.current_iteration,
      "calls_in_iteration" => sampler.calls_in_iteration
    }
  end

  @spec load!(map()) :: t()
  def load!(state) when is_map(state) do
    expected =
      ~w(minibatch_size trainset_identity shuffled_ids epoch id_freqs last_trainset_size current_iteration calls_in_iteration)

    load_with_size!(
      state,
      expected,
      Map.fetch!(state, "minibatch_size"),
      Map.fetch!(state, "trainset_identity")
    )
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid GEPA batch sampler checkpoint: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(state),
    do: raise(ArgumentError, "invalid GEPA batch sampler checkpoint: #{inspect(state)}")

  @doc false
  @spec load_size_only!(map()) :: t()
  def load_size_only!(state) when is_map(state) do
    expected =
      ~w(minibatch_size shuffled_ids epoch id_freqs last_trainset_size current_iteration calls_in_iteration)

    load_with_size!(state, expected, Map.fetch!(state, "minibatch_size"), nil)
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid legacy GEPA batch sampler checkpoint: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def load_size_only!(state),
    do: raise(ArgumentError, "invalid legacy GEPA batch sampler checkpoint: #{inspect(state)}")

  @doc false
  @spec load_legacy!(map(), pos_integer()) :: t()
  def load_legacy!(state, minibatch_size)
      when is_map(state) and is_integer(minibatch_size) and minibatch_size > 0 do
    expected =
      ~w(shuffled_ids epoch id_freqs last_trainset_size current_iteration calls_in_iteration)

    # Schema 6 wrote this provisional key before schema 7 made trainset
    # identity an enforced resume binding.  Accept and discard it on migration.
    state = discard_legacy_trainset_identity!(state)

    load_with_size!(state, expected, minibatch_size, nil)
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid legacy GEPA batch sampler checkpoint: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def load_legacy!(state, minibatch_size) do
    raise ArgumentError,
          "invalid legacy GEPA batch sampler checkpoint: #{inspect(state)} with size #{inspect(minibatch_size)}"
  end

  defp load_with_size!(state, expected, minibatch_size, trainset_identity) do
    unless MapSet.new(Map.keys(state)) == MapSet.new(expected) do
      raise ArgumentError, "GEPA batch sampler checkpoint has unexpected or missing keys"
    end

    sampler = %__MODULE__{
      minibatch_size: minibatch_size,
      trainset_identity: trainset_identity,
      shuffled_ids: Map.fetch!(state, "shuffled_ids"),
      epoch: Map.fetch!(state, "epoch"),
      id_freqs:
        Map.new(Map.fetch!(state, "id_freqs"), fn {id, count} ->
          {String.to_integer(id), count}
        end),
      last_trainset_size: Map.fetch!(state, "last_trainset_size"),
      current_iteration: Map.fetch!(state, "current_iteration"),
      calls_in_iteration: Map.fetch!(state, "calls_in_iteration")
    }

    validate!(sampler)
  end

  defp discard_legacy_trainset_identity!(state) do
    case Map.pop(state, "trainset_identity") do
      {nil, state} ->
        state

      {identity, state} when is_binary(identity) and byte_size(identity) == 64 ->
        state

      {identity, _state} ->
        raise ArgumentError,
              "GEPA legacy batch sampler checkpoint contains invalid trainset identity: #{inspect(identity)}"
    end
  end

  defp next_ids(sampler, trainset_size, size, iteration, rng_state) do
    calls = if sampler.current_iteration == iteration, do: sampler.calls_in_iteration + 1, else: 0
    base_index = iteration * size

    current_epoch =
      if sampler.epoch == -1,
        do: 0,
        else: div(base_index, max(length(sampler.shuffled_ids), 1))

    refresh? =
      sampler.shuffled_ids == [] or sampler.last_trainset_size != trainset_size or
        current_epoch > sampler.epoch

    {sampler, rng_state} =
      if refresh? do
        {ids, rng_state} = shuffled_indexes(trainset_size, rng_state)
        {ids, frequencies} = pad(ids, size)

        {%{
           sampler
           | shuffled_ids: ids,
             epoch: current_epoch,
             id_freqs: frequencies,
             last_trainset_size: trainset_size
         }, rng_state}
      else
        {sampler, rng_state}
      end

    sampler = %{sampler | current_iteration: iteration, calls_in_iteration: calls}
    offset = rem(base_index + calls * size, length(sampler.shuffled_ids))
    ids = Enum.slice(sampler.shuffled_ids, offset, size)

    if length(ids) != size do
      raise ArgumentError, "GEPA batch sampler produced a partial minibatch"
    end

    {ids, sampler, rng_state}
  end

  defp shuffled_indexes(size, rng_state) do
    0..(size - 1)
    |> Enum.map_reduce(rng_state, fn id, rng_state ->
      {key, rng_state} = :rand.uniform_s(rng_state)
      {{key, id}, rng_state}
    end)
    |> then(fn {decorated, rng_state} ->
      {decorated |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), rng_state}
    end)
  end

  defp pad(ids, size) do
    frequencies = Enum.frequencies(ids)
    remainder = rem(length(ids), size)
    needed = if remainder == 0, do: 0, else: size - remainder

    if needed == 0 do
      {ids, frequencies}
    else
      Enum.reduce(1..needed, {ids, frequencies}, fn _index, {ids, frequencies} ->
        minimum = frequencies |> Map.values() |> Enum.min()

        selected =
          ids
          |> Enum.reverse()
          |> Enum.find(&(Map.fetch!(frequencies, &1) == minimum))

        {ids ++ [selected], Map.update!(frequencies, selected, &(&1 + 1))}
      end)
    end
  end

  defp validate!(%__MODULE__{} = sampler) do
    valid_size? =
      is_nil(sampler.minibatch_size) or
        (is_integer(sampler.minibatch_size) and sampler.minibatch_size > 0)

    valid_ids? = Enum.all?(sampler.shuffled_ids, &(is_integer(&1) and &1 >= 0))

    valid_trainset_identity? =
      is_nil(sampler.trainset_identity) or
        (is_binary(sampler.trainset_identity) and byte_size(sampler.trainset_identity) == 64)

    valid_freqs? =
      Enum.all?(sampler.id_freqs, fn {id, count} ->
        is_integer(id) and id >= 0 and is_integer(count) and count > 0
      end)

    valid_iteration? =
      is_nil(sampler.current_iteration) or
        (is_integer(sampler.current_iteration) and sampler.current_iteration >= 0)

    unless valid_size? and valid_trainset_identity? and valid_ids? and valid_freqs? and
             is_integer(sampler.epoch) and
             sampler.epoch >= -1 and
             is_integer(sampler.last_trainset_size) and sampler.last_trainset_size >= 0 and
             valid_iteration? and is_integer(sampler.calls_in_iteration) and
             sampler.calls_in_iteration >= 0 do
      raise ArgumentError, "GEPA batch sampler checkpoint contains invalid fields"
    end

    sampler
  end

  defp trainset_identity(trainset) do
    trainset
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "GEPA trainset cannot be checkpoint-identified: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end
end
