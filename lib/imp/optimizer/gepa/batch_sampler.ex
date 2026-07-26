defmodule Imp.Optimizer.GEPA.BatchSampler do
  @moduledoc """
  Stateful minibatch selection for GEPA.

  The built-in epoch-shuffled strategy matches the pinned source default. A
  custom strategy is a struct whose module implements this behaviour. Its
  identity and state are checkpointed so resume cannot silently substitute or
  reset the consumer's sampling policy.
  """

  alias Imp.Optimizer.GEPA.Random

  @type rng_state :: Random.state()
  @type context :: %{iteration: non_neg_integer(), call_index: non_neg_integer()}

  @callback minibatch_size(struct()) :: pos_integer()
  @callback identity(struct()) :: term()
  @callback next_minibatch_ids(struct(), [term()], context(), rng_state()) ::
              {[non_neg_integer()], struct(), rng_state()}
  @callback dump_state(struct()) :: map()
  @callback load_state(struct(), map()) :: struct()

  defstruct minibatch_size: nil,
            trainset_identity: nil,
            shuffled_ids: [],
            epoch: -1,
            id_freqs: %{},
            last_trainset_size: 0,
            current_iteration: nil,
            calls_in_iteration: 0,
            custom_strategy: nil,
            custom_identity: nil

  @type t :: %__MODULE__{
          minibatch_size: pos_integer() | nil,
          trainset_identity: String.t() | nil,
          shuffled_ids: [non_neg_integer()],
          epoch: integer(),
          id_freqs: %{optional(non_neg_integer()) => pos_integer()},
          last_trainset_size: non_neg_integer(),
          current_iteration: non_neg_integer() | nil,
          calls_in_iteration: non_neg_integer(),
          custom_strategy: struct() | nil,
          custom_identity: term() | nil
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
  @spec new(:epoch_shuffled | struct(), pos_integer() | nil) :: t()
  def new(:epoch_shuffled, minibatch_size), do: new(minibatch_size)

  def new(%module{} = strategy, requested_size) do
    validate_strategy!(strategy)
    size = module.minibatch_size(strategy)

    if not is_nil(requested_size) and requested_size != size do
      raise ArgumentError,
            "custom GEPA batch sampler size #{size} does not match requested minibatch size #{requested_size}"
    end

    %__MODULE__{
      minibatch_size: size,
      custom_strategy: strategy,
      custom_identity: module.identity(strategy)
    }
  end

  def new(strategy, _minibatch_size) do
    raise ArgumentError,
          "GEPA batch sampler must be :epoch_shuffled or a strategy struct, got: #{inspect(strategy)}"
  end

  @doc false
  @spec validate_strategy!(:epoch_shuffled | struct()) :: :ok
  def validate_strategy!(:epoch_shuffled), do: :ok

  def validate_strategy!(%module{} = strategy) do
    required = [
      minibatch_size: 1,
      identity: 1,
      next_minibatch_ids: 4,
      dump_state: 1,
      load_state: 2
    ]

    unless Code.ensure_loaded?(module) and
             Enum.all?(required, fn {function, arity} ->
               function_exported?(module, function, arity)
             end) do
      raise ArgumentError,
            "GEPA batch sampler #{inspect(strategy)} must implement the #{inspect(__MODULE__)} behaviour"
    end

    size = module.minibatch_size(strategy)

    unless is_integer(size) and size > 0 do
      raise ArgumentError, "custom GEPA batch sampler minibatch_size/1 must be positive"
    end

    :ok
  end

  def validate_strategy!(strategy) do
    raise ArgumentError,
          "GEPA batch sampler must be :epoch_shuffled or a strategy struct, got: #{inspect(strategy)}"
  end

  @doc false
  def strategy_minibatch_size(:epoch_shuffled, requested), do: requested

  def strategy_minibatch_size(%module{} = strategy, nil) do
    validate_strategy!(strategy)
    module.minibatch_size(strategy)
  end

  def strategy_minibatch_size(%_{} = _strategy, requested) do
    raise ArgumentError,
          "reflection_minibatch_size cannot be combined with a custom batch sampler; the strategy owns its size (got #{inspect(requested)})"
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

    if sampler.custom_strategy && sampler.minibatch_size != size do
      raise ArgumentError,
            "custom GEPA batch sampler cannot be reconfigured from #{sampler.minibatch_size} to #{size}"
    else
      :ok
    end

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

    if sampler.custom_strategy do
      next_custom_batches(sampler, trainset, size, count, iteration, rng_state)
    else
      next_builtin_batches(sampler, trainset, size, count, iteration, rng_state)
    end
  end

  defp next_builtin_batches(sampler, trainset, size, count, iteration, rng_state) do
    {batches, {sampler, rng_state}} =
      Enum.map_reduce(1..count, {sampler, rng_state}, fn _call, {sampler, rng_state} ->
        {ids, sampler, rng_state} =
          next_ids(sampler, length(trainset), size, iteration, rng_state)

        {{Enum.map(ids, &Enum.fetch!(trainset, &1)), ids}, {sampler, rng_state}}
      end)

    {batches, sampler, rng_state}
  end

  defp next_custom_batches(sampler, trainset, size, count, iteration, rng_state) do
    {batches, {sampler, rng_state}} =
      Enum.map_reduce(1..count, {sampler, rng_state}, fn _call, {sampler, rng_state} ->
        call_index =
          if sampler.current_iteration == iteration,
            do: sampler.calls_in_iteration + 1,
            else: 0

        strategy = sampler.custom_strategy
        module = strategy.__struct__

        result =
          module.next_minibatch_ids(
            strategy,
            trainset,
            %{iteration: iteration, call_index: call_index},
            rng_state
          )

        {ids, strategy, rng_state} =
          validate_custom_result!(result, module, length(trainset), size)

        sampler = %{
          sampler
          | custom_strategy: strategy,
            current_iteration: iteration,
            calls_in_iteration: call_index,
            last_trainset_size: length(trainset)
        }

        {{Enum.map(ids, &Enum.fetch!(trainset, &1)), ids}, {sampler, rng_state}}
      end)

    {batches, sampler, rng_state}
  end

  defp validate_custom_result!(
         {ids, %{__struct__: returned_module} = strategy, rng_state},
         module,
         trainset_size,
         size
       )
       when returned_module == module do
    valid_ids? =
      is_list(ids) and length(ids) == size and
        Enum.all?(ids, fn id -> is_integer(id) and id >= 0 and id < trainset_size end)

    unless valid_ids? do
      raise ArgumentError,
            "custom GEPA batch sampler must return #{size} trainset indexes within 0..#{trainset_size - 1}"
    end

    validate_rng!(rng_state)
    {ids, strategy, rng_state}
  end

  defp validate_custom_result!(result, module, _trainset_size, _size) do
    raise ArgumentError,
          "custom GEPA batch sampler #{inspect(module)} returned invalid result: #{inspect(result)}"
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{custom_strategy: %module{} = strategy} = sampler) do
    unless module.identity(strategy) == sampler.custom_identity do
      raise ArgumentError,
            "custom GEPA batch sampler identity/1 must remain stable while callback state changes"
    end

    state = module.dump_state(strategy)

    unless is_map(state) do
      raise ArgumentError, "custom GEPA batch sampler dump_state/1 must return a map"
    end

    %{
      "strategy" => "custom",
      "module" => Atom.to_string(module),
      "identity" => encode_checkpoint_term!(sampler.custom_identity, "identity"),
      "state" => encode_checkpoint_term!(state, "state"),
      "minibatch_size" => sampler.minibatch_size,
      "trainset_identity" => sampler.trainset_identity,
      "last_trainset_size" => sampler.last_trainset_size,
      "current_iteration" => sampler.current_iteration,
      "calls_in_iteration" => sampler.calls_in_iteration
    }
  end

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
  def load!(state), do: load!(state, :epoch_shuffled)

  @doc false
  @spec load!(map(), :epoch_shuffled | struct()) :: t()
  def load!(%{"strategy" => "custom"} = state, %module{} = requested_strategy) do
    expected =
      ~w(strategy module identity state minibatch_size trainset_identity last_trainset_size current_iteration calls_in_iteration)

    unless MapSet.new(Map.keys(state)) == MapSet.new(expected) do
      raise ArgumentError, "custom GEPA batch sampler checkpoint has unexpected or missing keys"
    end

    validate_strategy!(requested_strategy)

    unless state["module"] == Atom.to_string(module) do
      raise ArgumentError, "GEPA resume batch sampler module does not match"
    end

    stored_identity = Imp.Optimizer.Report.decode_term(state["identity"])

    unless stored_identity == module.identity(requested_strategy) do
      raise ArgumentError, "GEPA resume batch sampler identity does not match"
    end

    restored_state = Imp.Optimizer.Report.decode_term(state["state"])
    restored_strategy = load_custom_state!(module, requested_strategy, restored_state)

    unless match?(%{__struct__: ^module}, restored_strategy) do
      raise ArgumentError, "custom GEPA batch sampler load_state/2 returned the wrong struct"
    end

    %__MODULE__{
      minibatch_size: state["minibatch_size"],
      trainset_identity: state["trainset_identity"],
      last_trainset_size: state["last_trainset_size"],
      current_iteration: state["current_iteration"],
      calls_in_iteration: state["calls_in_iteration"],
      custom_strategy: restored_strategy,
      custom_identity: stored_identity
    }
    |> validate!()
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid GEPA batch sampler checkpoint: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(%{"strategy" => "custom"}, requested) do
    raise ArgumentError,
          "GEPA custom batch sampler checkpoint requires the matching strategy struct, got: #{inspect(requested)}"
  end

  def load!(state, :epoch_shuffled) when is_map(state) do
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

  def load!(state, requested),
    do:
      raise(
        ArgumentError,
        "invalid GEPA batch sampler checkpoint #{inspect(state)} for #{inspect(requested)}"
      )

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
    Random.shuffle(Enum.to_list(0..(size - 1)), rng_state)
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

    valid_custom? =
      case sampler.custom_strategy do
        nil -> is_nil(sampler.custom_identity)
        %module{} = strategy -> module.identity(strategy) == sampler.custom_identity
        _other -> false
      end

    unless valid_size? and valid_trainset_identity? and valid_ids? and valid_freqs? and
             is_integer(sampler.epoch) and
             sampler.epoch >= -1 and
             is_integer(sampler.last_trainset_size) and sampler.last_trainset_size >= 0 and
             valid_iteration? and is_integer(sampler.calls_in_iteration) and
             sampler.calls_in_iteration >= 0 and valid_custom? do
      raise ArgumentError, "GEPA batch sampler checkpoint contains invalid fields"
    end

    sampler
  end

  defp validate_rng!(rng_state) do
    if Random.valid?(rng_state),
      do: :ok,
      else: raise(ArgumentError, "custom GEPA batch sampler returned an invalid RNG state")
  end

  defp encode_checkpoint_term!(value, field) do
    encoded = Imp.Optimizer.Report.encode_term(value)

    case Jason.encode(encoded) do
      {:ok, _json} ->
        encoded

      {:error, error} ->
        raise ArgumentError,
              "custom GEPA batch sampler #{field} is not JSON-safe: #{Exception.message(error)}"
    end
  end

  defp load_custom_state!(module, requested_strategy, state) do
    module.load_state(requested_strategy, state)
  rescue
    error ->
      raise ArgumentError,
            "custom GEPA batch sampler load_state/2 failed: #{Exception.message(error)}"
  catch
    kind, reason ->
      raise ArgumentError,
            "custom GEPA batch sampler load_state/2 failed with #{kind}: #{inspect(reason)}"
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
