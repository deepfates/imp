defmodule Imp.Optimizer.MIPROv2.Config do
  @moduledoc false

  @auto_settings %{
    light: %{n: 6, val_size: 100},
    medium: %{n: 12, val_size: 300},
    heavy: %{n: 18, val_size: 1_000}
  }
  @min_minibatch_size 50

  @enforce_keys []
  defstruct auto: :light,
            num_candidates: nil,
            num_trials: nil,
            max_bootstrapped_demos: 4,
            max_labeled_demos: 4,
            seed: 9,
            minibatch: true,
            minibatch_size: 35,
            minibatch_full_eval_steps: 5,
            program_aware_proposer: true,
            data_aware_proposer: true,
            view_data_batch_size: 10,
            tip_aware_proposer: true,
            fewshot_aware_proposer: true,
            proposer_fidelity: :beam_native,
            trainset: nil,
            valset: nil,
            zeroshot: nil,
            num_instruct_candidates: nil,
            num_fewshot_candidates: nil

  @type auto_mode :: :light | :medium | :heavy | nil
  @type t :: %__MODULE__{}

  @option_keys [
    :auto,
    :num_candidates,
    :num_trials,
    :max_bootstrapped_demos,
    :max_labeled_demos,
    :seed,
    :minibatch,
    :minibatch_size,
    :minibatch_full_eval_steps,
    :program_aware_proposer,
    :data_aware_proposer,
    :view_data_batch_size,
    :tip_aware_proposer,
    :fewshot_aware_proposer,
    :proposer_fidelity
  ]

  @doc false
  def option_keys, do: @option_keys

  @doc "Creates a validated, unresolved MIPROv2 configuration."
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    reject_unknown!(opts, @option_keys)

    config = struct!(__MODULE__, opts)
    validate!(config)
  end

  def new(_opts), do: raise(ArgumentError, "MIPROv2 config options must be a keyword list")

  @doc """
  Resolves search settings for `predictor_count` predictors and the supplied datasets.

  The final argument accepts compile-time overrides for any constructor option.
  `:valset` may be supplied there as an alternative to the third argument.
  """
  @spec resolve(t(), non_neg_integer(), Enumerable.t(), Enumerable.t() | nil, keyword()) :: t()
  def resolve(%__MODULE__{} = config, predictor_count, trainset, valset, overrides)
      when is_integer(predictor_count) and predictor_count >= 0 and is_list(overrides) do
    valset = Keyword.get(overrides, :valset, valset)
    overrides = Keyword.delete(overrides, :valset)

    overrides =
      if Keyword.get(overrides, :seed) == 0, do: Keyword.delete(overrides, :seed), else: overrides

    reject_unknown!(overrides, @option_keys)

    resolved =
      config
      |> Map.from_struct()
      |> Map.merge(Map.new(overrides))
      |> then(&struct!(__MODULE__, &1))

    validate!(resolved)
    validate_mode!(resolved)

    {trainset, valset} = validate_datasets!(trainset, valset)
    zeroshot = resolved.max_bootstrapped_demos == 0 and resolved.max_labeled_demos == 0

    resolved
    |> Map.put(:trainset, trainset)
    |> Map.put(:valset, valset)
    |> Map.put(:zeroshot, zeroshot)
    |> derive_run_settings(predictor_count)
    |> validate_minibatch!()
  end

  @spec resolve(t(), non_neg_integer(), Enumerable.t()) :: t()
  def resolve(%__MODULE__{} = config, predictor_count, trainset) do
    resolve(config, predictor_count, trainset, nil, [])
  end

  @spec resolve(t(), non_neg_integer(), Enumerable.t(), Enumerable.t() | keyword()) :: t()
  def resolve(%__MODULE__{} = config, predictor_count, trainset, valset_or_overrides) do
    override_keys =
      if Keyword.keyword?(valset_or_overrides), do: Keyword.keys(valset_or_overrides), else: []

    if valset_or_overrides != [] and
         Enum.any?(override_keys, &(&1 in @option_keys or &1 == :valset)) do
      resolve(config, predictor_count, trainset, nil, valset_or_overrides)
    else
      resolve(config, predictor_count, trainset, valset_or_overrides, [])
    end
  end

  @doc "Returns DSPy's recommended trial count for a candidate budget."
  @spec recommended_num_trials(non_neg_integer(), boolean(), pos_integer()) :: non_neg_integer()
  def recommended_num_trials(predictor_count, zeroshot, num_candidates)
      when is_integer(predictor_count) and predictor_count >= 0 and is_boolean(zeroshot) and
             is_integer(num_candidates) and num_candidates > 0 do
    variables = if zeroshot, do: predictor_count, else: predictor_count * 2
    trunc(max(2 * variables * :math.log2(num_candidates), 1.5 * num_candidates))
  end

  defp derive_run_settings(%{auto: nil} = config, _predictor_count) do
    %{
      config
      | num_instruct_candidates: config.num_candidates,
        num_fewshot_candidates: config.num_candidates
    }
  end

  defp derive_run_settings(config, predictor_count) do
    %{n: n, val_size: val_size} = Map.fetch!(@auto_settings, config.auto)
    valset = seeded_take(config.valset, val_size, config.seed)

    %{
      config
      | valset: valset,
        minibatch: length(valset) > @min_minibatch_size,
        num_trials: recommended_num_trials(predictor_count, config.zeroshot, n),
        num_instruct_candidates: if(config.zeroshot, do: n, else: trunc(n * 0.5)),
        num_fewshot_candidates: n
    }
  end

  defp validate_mode!(%{auto: nil, num_candidates: candidates, num_trials: trials})
       when not is_nil(candidates) and not is_nil(trials),
       do: :ok

  defp validate_mode!(%{auto: nil, num_candidates: candidates, num_trials: nil})
       when not is_nil(candidates) do
    raise ArgumentError,
          "when auto is nil, num_trials must be provided with num_candidates"
  end

  defp validate_mode!(%{auto: nil}) do
    raise ArgumentError, "when auto is nil, num_candidates and num_trials must be provided"
  end

  defp validate_mode!(%{num_candidates: nil, num_trials: nil}), do: :ok

  defp validate_mode!(_config) do
    raise ArgumentError,
          "num_candidates and num_trials cannot be set when auto is enabled"
  end

  defp validate_datasets!(trainset, valset) do
    trainset = materialize!(trainset, "trainset")

    if trainset == [], do: raise(ArgumentError, "trainset cannot be empty")

    if is_nil(valset) do
      if length(trainset) < 2,
        do: raise(ArgumentError, "trainset must have at least 2 examples when valset is omitted")

      val_size = min(1_000, max(1, trunc(length(trainset) * 0.8)))
      Enum.split(trainset, length(trainset) - val_size)
    else
      valset = materialize!(valset, "valset")
      if valset == [], do: raise(ArgumentError, "valset must have at least 1 example")
      {trainset, valset}
    end
  end

  defp materialize!(enumerable, name) do
    Enum.to_list(enumerable)
  rescue
    Protocol.UndefinedError ->
      reraise ArgumentError, [message: "#{name} must be enumerable"], __STACKTRACE__
  end

  defp seeded_take(values, count, _seed) when length(values) <= count, do: values

  defp seeded_take(values, count, seed) do
    state = :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3})

    values
    |> Enum.map_reduce(state, fn value, state ->
      {key, state} = :rand.uniform_s(state)
      {{key, value}, state}
    end)
    |> elem(0)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(count)
    |> Enum.map(&elem(&1, 1))
  end

  defp validate!(config) do
    unless config.auto in [nil, :light, :medium, :heavy],
      do: raise(ArgumentError, "auto must be nil, :light, :medium, or :heavy")

    validate_optional_positive!(config.num_candidates, :num_candidates)
    validate_optional_non_negative!(config.num_trials, :num_trials)
    validate_non_negative!(config.max_bootstrapped_demos, :max_bootstrapped_demos)
    validate_non_negative!(config.max_labeled_demos, :max_labeled_demos)
    validate_non_negative!(config.seed, :seed)
    validate_positive!(config.minibatch_size, :minibatch_size)
    validate_positive!(config.minibatch_full_eval_steps, :minibatch_full_eval_steps)
    validate_positive!(config.view_data_batch_size, :view_data_batch_size)

    for key <- [
          :minibatch,
          :program_aware_proposer,
          :data_aware_proposer,
          :tip_aware_proposer,
          :fewshot_aware_proposer
        ] do
      unless is_boolean(Map.fetch!(config, key)),
        do: raise(ArgumentError, "#{key} must be a boolean")
    end

    unless config.proposer_fidelity in [:beam_native, :dspy_3_2_1],
      do: raise(ArgumentError, "proposer_fidelity must be :beam_native or :dspy_3_2_1")

    if config.proposer_fidelity == :dspy_3_2_1 and
         (config.program_aware_proposer or config.fewshot_aware_proposer or
            not config.data_aware_proposer or not config.tip_aware_proposer) do
      raise ArgumentError,
            ":dspy_3_2_1 proposer fidelity currently requires program_aware_proposer: false, " <>
              "fewshot_aware_proposer: false, data_aware_proposer: true, and tip_aware_proposer: true"
    end

    config
  end

  defp validate_minibatch!(%{minibatch: true, minibatch_size: size, valset: valset} = config) do
    if size > length(valset),
      do: raise(ArgumentError, "minibatch_size cannot exceed valset size #{length(valset)}")

    config
  end

  defp validate_minibatch!(config), do: config

  defp validate_optional_positive!(nil, _key), do: :ok
  defp validate_optional_positive!(value, key), do: validate_positive!(value, key)
  defp validate_optional_non_negative!(nil, _key), do: :ok
  defp validate_optional_non_negative!(value, key), do: validate_non_negative!(value, key)

  defp validate_positive!(value, _key) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(_value, key),
    do: raise(ArgumentError, "#{key} must be a positive integer")

  defp validate_non_negative!(value, _key) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative!(_value, key),
    do: raise(ArgumentError, "#{key} must be a non-negative integer")

  defp reject_unknown!(opts, allowed) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "MIPROv2 config options must be a keyword list")

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      keys -> raise ArgumentError, "unknown MIPROv2 config options: #{inspect(keys)}"
    end
  end
end
