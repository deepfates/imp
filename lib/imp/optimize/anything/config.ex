defmodule Imp.Optimize.Anything.Config do
  @moduledoc """
  Immutable configuration for the GEPA v0.1.4 Optimize Anything frontend.

  The released Python frontend supplies a default external reflection model.
  Imp deliberately does not: `reflection.reflection_lm` defaults to `nil` and
  must be supplied by the execution layer whenever reflection is required.
  """

  alias Imp.Optimize.Anything.Config.{Engine, Merge, Refiner, Reflection, Tracking}

  alias Imp.Optimizer.GEPA.{
    BatchSampler,
    Callback,
    CandidateSelector,
    ModuleSelector,
    ProposalSelection,
    Stopper
  }

  defmodule Persistence do
    @moduledoc false

    def encode(struct, runtime_fields \\ []) do
      struct
      |> Map.from_struct()
      |> Enum.reject(fn {key, value} -> key in runtime_fields and is_nil(value) end)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), json_safe!(value, [key])} end)
    end

    def options!(value, context, enum_fields \\ [])

    def options!(map, context, enum_fields) when is_map(map) do
      Map.new(map, fn {key, value} ->
        key = key!(key, context)
        value = if key in enum_fields, do: atom_value(value), else: value
        {key, value}
      end)
      |> Map.to_list()
    end

    def options!(value, context, _enum_fields) do
      raise ArgumentError, "#{context} expects a map, got: #{inspect(value)}"
    end

    def fetch_type!(map, expected, context) do
      actual = Map.get(map, "type", Map.get(map, :type))

      unless actual == expected do
        raise ArgumentError,
              "#{context} expects type #{inspect(expected)}, got: #{inspect(actual)}"
      end
    end

    def json_safe!(nil, _path), do: nil

    def json_safe!(value, _path) when is_boolean(value) or is_number(value) or is_binary(value),
      do: value

    def json_safe!(value, _path) when is_atom(value), do: Atom.to_string(value)

    def json_safe!(values, path) when is_list(values) do
      values
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> json_safe!(value, [index | path]) end)
    end

    def json_safe!(%_{} = value, path), do: runtime_value!(value, path)

    def json_safe!(map, path) when is_map(map) do
      Map.new(map, fn {key, value} ->
        unless is_atom(key) or is_binary(key) do
          runtime_value!(map, path)
        end

        {to_string(key), json_safe!(value, [key | path])}
      end)
    end

    def json_safe!(value, path), do: runtime_value!(value, path)

    defp key!(key, _context) when is_atom(key), do: key

    defp key!(key, _context) when is_binary(key), do: String.to_existing_atom(key)

    defp key!(key, context),
      do: raise(ArgumentError, "#{context} has invalid option key #{inspect(key)}")

    defp atom_value(value) when is_binary(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end

    defp atom_value(value), do: value

    defp runtime_value!(value, path) do
      field = path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)

      raise ArgumentError,
            "Optimize Anything config field #{field} contains a runtime-only value that cannot be persisted: #{inspect(value)}"
    end
  end

  defmodule Engine do
    @moduledoc "Run-loop, budget, caching, selection, and parallelism settings."

    alias Imp.Optimize.Anything.Config.Persistence

    @default_max_workers System.schedulers_online()
    @enum_fields [
      :val_evaluation_policy,
      :candidate_selection_strategy,
      :acceptance_criterion,
      :sampling_strategy,
      :selection_strategy,
      :frontier_type,
      :cache_evaluation_storage
    ]
    @schema [
      run_dir: [type: {:or, [:string, nil]}, default: nil],
      seed: [type: :non_neg_integer, default: 0],
      display_progress_bar: [type: :boolean, default: false],
      raise_on_exception: [type: :boolean, default: true],
      track_best_outputs: [type: :boolean, default: false],
      max_metric_calls: [type: {:or, [:non_neg_integer, nil]}, default: nil],
      max_candidate_proposals: [type: {:or, [:non_neg_integer, nil]}, default: nil],
      max_full_evaluations: [type: {:or, [:non_neg_integer, nil]}, default: nil],
      max_reflection_cost: [
        type: {:custom, __MODULE__, :validate_optional_non_negative_number, []},
        default: nil
      ],
      val_evaluation_policy: [type: :any, default: :full_eval],
      candidate_selection_strategy: [type: :any, default: :pareto],
      acceptance_criterion: [type: :any, default: :strict_improvement],
      sampling_strategy: [type: :any, default: nil],
      selection_strategy: [type: :any, default: nil],
      frontier_type: [type: {:in, [:instance, :objective, :hybrid, :cartesian]}, default: :hybrid],
      parallel: [type: :boolean, default: true],
      max_workers: [type: {:or, [:pos_integer, nil]}, default: @default_max_workers],
      cache_evaluation: [type: :boolean, default: false],
      cache_evaluation_storage: [type: {:in, [:memory, :disk, :auto]}, default: :auto],
      best_example_evals_k: [type: :non_neg_integer, default: 30],
      capture_stdio: [type: :boolean, default: false]
    ]

    defstruct run_dir: nil,
              seed: 0,
              display_progress_bar: false,
              raise_on_exception: true,
              track_best_outputs: false,
              max_metric_calls: nil,
              max_candidate_proposals: nil,
              max_full_evaluations: nil,
              max_reflection_cost: nil,
              val_evaluation_policy: :full_eval,
              candidate_selection_strategy: :pareto,
              acceptance_criterion: :strict_improvement,
              sampling_strategy: nil,
              selection_strategy: nil,
              frontier_type: :hybrid,
              parallel: true,
              max_workers: @default_max_workers,
              cache_evaluation: false,
              cache_evaluation_storage: :auto,
              best_example_evals_k: 30,
              capture_stdio: false

    @type t :: %__MODULE__{}

    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      values = Imp.Options.validate!(opts, @schema, "#{inspect(__MODULE__)}.new/1")
      values = normalize_persisted_strategies(values)
      config = struct!(__MODULE__, values)
      validate_strategies!(config)
      validate_cache!(config)
      config
    end

    @spec cache_mode(t()) :: :off | :memory | :disk
    def cache_mode(%__MODULE__{cache_evaluation: false}), do: :off
    def cache_mode(%__MODULE__{cache_evaluation_storage: :auto, run_dir: nil}), do: :memory
    def cache_mode(%__MODULE__{cache_evaluation_storage: :auto}), do: :disk
    def cache_mode(%__MODULE__{cache_evaluation_storage: mode}), do: mode

    @doc false
    def validate_optional_non_negative_number(nil), do: {:ok, nil}

    def validate_optional_non_negative_number(value) when is_number(value) and value >= 0,
      do: {:ok, value}

    def validate_optional_non_negative_number(_value),
      do: {:error, "expected a non-negative number or nil"}

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = config) do
      config
      |> Map.from_struct()
      |> Map.put(:sampling_strategy, dump_sampling_strategy(config.sampling_strategy))
      |> Map.put(:selection_strategy, dump_selection_strategy(config.selection_strategy))
      |> then(&struct!(__MODULE__, &1))
      |> Persistence.encode()
    end

    @spec from_map(map()) :: t()
    def from_map(map),
      do: map |> Persistence.options!("#{inspect(__MODULE__)}.from_map/1", @enum_fields) |> new()

    defp validate_strategies!(config) do
      CandidateSelector.validate!(config.candidate_selection_strategy)
      validate_sampling_strategy!(config.sampling_strategy)
      ProposalSelection.validate!(config.selection_strategy || :all_improvements)
      validate_acceptance_criterion!(config.acceptance_criterion)

      unless config.val_evaluation_policy in [:full_eval, :full] or
               is_atom(config.val_evaluation_policy) do
        raise ArgumentError, "val_evaluation_policy must be :full_eval, :full, or a policy module"
      end
    end

    defp validate_sampling_strategy!(nil), do: :ok
    defp validate_sampling_strategy!(:single), do: :ok

    defp validate_sampling_strategy!({kind, count})
         when kind in [:same_parent, :independent] and is_integer(count) and count > 0,
         do: :ok

    defp validate_sampling_strategy!({:pxn, parents, mutations})
         when is_integer(parents) and parents > 0 and is_integer(mutations) and mutations > 0,
         do: :ok

    defp validate_sampling_strategy!(strategy) do
      raise ArgumentError,
            "sampling_strategy must be nil, :single, {:same_parent, n}, {:independent, n}, or {:pxn, p, n}; custom upstream strategy objects are not supported by the Optimize Anything config, got: #{inspect(strategy)}"
    end

    defp validate_acceptance_criterion!(criterion)
         when criterion in [:strict_improvement, :improvement_or_equal, :equal_or_better],
         do: :ok

    defp validate_acceptance_criterion!({:callback, callback})
         when is_function(callback, 1),
         do: :ok

    defp validate_acceptance_criterion!(criterion) do
      raise ArgumentError,
            "acceptance_criterion must be :strict_improvement, :improvement_or_equal, or a BEAM-native {:callback, arity_1_function}; custom upstream criterion objects are not supported by the Optimize Anything config, got: #{inspect(criterion)}"
    end

    defp normalize_persisted_strategies(values) do
      values
      |> Keyword.update(:sampling_strategy, nil, &load_sampling_strategy/1)
      |> Keyword.update(:selection_strategy, nil, &load_selection_strategy/1)
    end

    defp dump_sampling_strategy({kind, count}) when kind in [:same_parent, :independent],
      do: %{"type" => Atom.to_string(kind), "count" => count}

    defp dump_sampling_strategy({:pxn, parents, mutations}),
      do: %{"type" => "pxn", "parents" => parents, "mutations" => mutations}

    defp dump_sampling_strategy(strategy), do: strategy

    defp load_sampling_strategy(%{"type" => type, "count" => count})
         when type in ["same_parent", "independent"],
         do: {String.to_existing_atom(type), count}

    defp load_sampling_strategy(%{
           "type" => "pxn",
           "parents" => parents,
           "mutations" => mutations
         }),
         do: {:pxn, parents, mutations}

    defp load_sampling_strategy(strategy), do: strategy

    defp dump_selection_strategy({:top_k, count}),
      do: %{"type" => "top_k", "count" => count}

    defp dump_selection_strategy(strategy), do: strategy

    defp load_selection_strategy(%{"type" => "top_k", "count" => count}), do: {:top_k, count}
    defp load_selection_strategy(strategy), do: strategy

    defp validate_cache!(%{cache_evaluation: true, cache_evaluation_storage: :disk, run_dir: nil}) do
      raise ArgumentError, "cache_evaluation_storage :disk requires run_dir"
    end

    defp validate_cache!(_config), do: :ok
  end

  defmodule Reflection do
    @moduledoc "Reflection proposal and minibatch settings."

    alias Imp.Optimize.Anything.Config.Persistence
    alias Imp.Optimizer.GEPA.ReflectionStrategy

    @enum_fields [:batch_sampler, :module_selector, :structured_response_format]
    @schema [
      skip_perfect_score: [type: :boolean, default: false],
      perfect_score: [type: :any, default: nil],
      batch_sampler: [type: :any, default: :epoch_shuffled],
      reflection_minibatch_size: [type: {:or, [:pos_integer, nil]}, default: nil],
      module_selector: [type: :any, default: :round_robin],
      structured_response_format: [
        type: {:in, [:off, :auto, :required]},
        default: :off
      ],
      reflection_strategy: [type: :any, default: nil],
      reflection_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
      reflection_prompt_template: [type: {:or, [:string, :map, nil]}, default: nil],
      custom_candidate_proposer: [type: :any, default: nil]
    ]

    defstruct skip_perfect_score: false,
              perfect_score: nil,
              batch_sampler: :epoch_shuffled,
              reflection_minibatch_size: nil,
              module_selector: :round_robin,
              structured_response_format: :off,
              reflection_strategy: nil,
              reflection_lm: nil,
              reflection_prompt_template: nil,
              custom_candidate_proposer: nil

    @type t :: %__MODULE__{}

    @doc "Creates reflection settings without selecting an external model provider."
    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      values = Imp.Options.validate!(opts, @schema, "#{inspect(__MODULE__)}.new/1")
      config = struct!(__MODULE__, values)
      validate_perfect_score!(config.perfect_score)
      BatchSampler.validate_strategy!(config.batch_sampler)
      BatchSampler.strategy_minibatch_size(config.batch_sampler, config.reflection_minibatch_size)
      ModuleSelector.validate!(config.module_selector)
      ReflectionStrategy.validate!(config.reflection_strategy)
      validate_proposer!(config.custom_candidate_proposer)
      config
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = config), do: Persistence.encode(config)

    @spec from_map(map()) :: t()
    def from_map(map),
      do: map |> Persistence.options!("#{inspect(__MODULE__)}.from_map/1", @enum_fields) |> new()

    defp validate_proposer!(nil), do: :ok
    defp validate_proposer!(proposer) when is_function(proposer, 4), do: :ok

    defp validate_proposer!(_proposer),
      do: raise(ArgumentError, "custom_candidate_proposer must be nil or an arity-4 function")

    defp validate_perfect_score!(nil), do: :ok
    defp validate_perfect_score!(score) when is_number(score), do: :ok

    defp validate_perfect_score!(_score),
      do: raise(ArgumentError, "perfect_score must be nil or a number")
  end

  defmodule Merge do
    @moduledoc "Optional Pareto-frontier merge settings."

    alias Imp.Optimize.Anything.Config.Persistence

    @schema [
      max_merge_invocations: [type: :non_neg_integer, default: 5],
      merge_val_overlap_floor: [type: :pos_integer, default: 5],
      merge_subsample_size: [type: :pos_integer, default: 5]
    ]

    defstruct max_merge_invocations: 5,
              merge_val_overlap_floor: 5,
              merge_subsample_size: 5

    @type t :: %__MODULE__{}

    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      opts
      |> Imp.Options.validate!(@schema, "#{inspect(__MODULE__)}.new/1")
      |> then(&struct!(__MODULE__, &1))
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = config), do: Persistence.encode(config)

    @spec from_map(map()) :: t()
    def from_map(map),
      do: map |> Persistence.options!("#{inspect(__MODULE__)}.from_map/1") |> new()
  end

  defmodule Refiner do
    @moduledoc "Optional per-evaluation candidate refinement settings."

    alias Imp.Optimize.Anything.Config.Persistence

    @schema [
      refiner_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
      max_refinements: [type: :pos_integer, default: 1]
    ]

    defstruct refiner_lm: nil, max_refinements: 1

    @type t :: %__MODULE__{}

    @doc "Creates refiner settings; execution may inherit `reflection_lm` when this LM is nil."
    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      opts
      |> Imp.Options.validate!(@schema, "#{inspect(__MODULE__)}.new/1")
      |> then(&struct!(__MODULE__, &1))
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = config), do: Persistence.encode(config)

    @spec from_map(map()) :: t()
    def from_map(map),
      do: map |> Persistence.options!("#{inspect(__MODULE__)}.from_map/1") |> new()
  end

  defmodule Tracking do
    @moduledoc "Optional logger, W&B, and MLflow tracking settings."

    alias Imp.Optimize.Anything.Config.Persistence

    @schema [
      logger: [type: :any, default: nil],
      use_wandb: [type: :boolean, default: false],
      wandb_api_key: [type: {:or, [:string, nil]}, default: nil],
      wandb_init_kwargs: [type: {:or, [:map, nil]}, default: nil],
      use_mlflow: [type: :boolean, default: false],
      mlflow_tracking_uri: [type: {:or, [:string, nil]}, default: nil],
      mlflow_experiment_name: [type: {:or, [:string, nil]}, default: nil]
    ]

    defstruct logger: nil,
              use_wandb: false,
              wandb_api_key: nil,
              wandb_init_kwargs: nil,
              use_mlflow: false,
              mlflow_tracking_uri: nil,
              mlflow_experiment_name: nil

    @type t :: %__MODULE__{}

    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      opts
      |> Imp.Options.validate!(@schema, "#{inspect(__MODULE__)}.new/1")
      |> then(&struct!(__MODULE__, &1))
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = config) do
      config
      |> Map.put(:wandb_api_key, nil)
      |> Persistence.encode()
    end

    @spec from_map(map()) :: t()
    def from_map(map),
      do: map |> Persistence.options!("#{inspect(__MODULE__)}.from_map/1") |> new()
  end

  @schema [
    engine: [type: :any, default: nil],
    reflection: [type: :any, default: nil],
    merge: [type: :any, default: nil],
    refiner: [type: :any, default: nil],
    tracking: [type: :any, default: nil],
    stopper: [type: :any, default: nil],
    callbacks: [type: {:list, :any}, default: []]
  ]

  defstruct engine: nil,
            reflection: nil,
            merge: nil,
            refiner: nil,
            tracking: nil,
            stopper: nil,
            callbacks: []

  @type t :: %__MODULE__{
          engine: Engine.t(),
          reflection: Reflection.t(),
          merge: Merge.t() | nil,
          refiner: Refiner.t() | nil,
          tracking: Tracking.t(),
          stopper: term() | nil,
          callbacks: [Imp.Optimizer.GEPA.Callback.callback()]
        }

  @doc "Creates a validated nested Optimize Anything configuration."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    values = Imp.Options.validate!(opts, @schema, "#{inspect(__MODULE__)}.new/1")

    config = %__MODULE__{
      engine: nested(values[:engine], Engine, false),
      reflection: nested(values[:reflection], Reflection, false),
      merge: nested(values[:merge], Merge, true),
      refiner: nested(values[:refiner], Refiner, true),
      tracking: nested(values[:tracking], Tracking, false),
      stopper: values[:stopper],
      callbacks: values[:callbacks]
    }

    validate_runtime!(config)
    config
  end

  @doc "Returns keyword options consumed by the production optimizer engine."
  @spec to_engine_options(t()) :: keyword()
  def to_engine_options(%__MODULE__{} = config) do
    engine = config.engine
    reflection = config.reflection

    [
      seed: engine.seed,
      raise_on_exception: engine.raise_on_exception,
      max_metric_calls: engine.max_metric_calls || :infinity,
      max_full_evaluations: engine.max_full_evaluations || :infinity,
      max_reflection_cost: engine.max_reflection_cost,
      reflection_cost_source: reflection.reflection_lm,
      reflection_strategy: reflection.reflection_strategy,
      frontier_type: engine.frontier_type,
      cache_evaluation: engine.cache_evaluation,
      cache_evaluation_storage: cache_storage(engine),
      candidate_selection_strategy: engine.candidate_selection_strategy,
      acceptance_policy: acceptance_policy(engine.acceptance_criterion),
      sampling_strategy: engine.sampling_strategy,
      selection_strategy: engine.selection_strategy,
      proposal_concurrency: proposal_width(engine.sampling_strategy),
      batch_sampler: reflection.batch_sampler,
      module_selector: reflection.module_selector,
      track_best_outputs: engine.track_best_outputs,
      evaluation_policy: evaluation_policy(engine.val_evaluation_policy),
      minibatch_size: reflection.reflection_minibatch_size,
      skip_perfect_score: reflection.skip_perfect_score,
      perfect_score: reflection.perfect_score,
      max_reflection_calls: :infinity,
      stopper: config.stopper,
      callbacks: config.callbacks
    ]
    |> maybe_add(:max_iterations, engine.max_candidate_proposals)
    |> add_merge(config.merge)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "Converts the complete nested config to versioned JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    ensure_persistable_runtime!(config)

    %{
      "type" => "imp_optimize_anything_config",
      "schema_version" => 1,
      "engine" => Engine.to_map(config.engine),
      "reflection" => Reflection.to_map(config.reflection),
      "merge" => if(config.merge, do: Merge.to_map(config.merge)),
      "refiner" => if(config.refiner, do: Refiner.to_map(config.refiner)),
      "tracking" => Tracking.to_map(config.tracking),
      "stopper" => config.stopper,
      "callbacks" => []
    }
  end

  @doc "Restores a config emitted by `to_map/1`."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    Persistence.fetch_type!(
      map,
      "imp_optimize_anything_config",
      "#{inspect(__MODULE__)}.from_map/1"
    )

    unless Map.get(map, "schema_version", Map.get(map, :schema_version)) == 1 do
      raise ArgumentError, "#{inspect(__MODULE__)}.from_map/1 expects schema_version 1"
    end

    new(
      engine: map |> fetch!(:engine) |> Engine.from_map(),
      reflection: map |> fetch!(:reflection) |> Reflection.from_map(),
      merge: optional_nested(map, :merge, Merge),
      refiner: optional_nested(map, :refiner, Refiner),
      tracking: map |> fetch!(:tracking) |> Tracking.from_map(),
      stopper: Map.get(map, "stopper", Map.get(map, :stopper)),
      callbacks: Map.get(map, "callbacks", Map.get(map, :callbacks, []))
    )
  end

  def from_map(value) do
    raise ArgumentError, "#{inspect(__MODULE__)}.from_map/1 expects a map, got: #{inspect(value)}"
  end

  defp nested(nil, module, false), do: module.new()
  defp nested(nil, _module, true), do: nil
  defp nested(%module{} = config, module, _optional), do: config
  defp nested(opts, module, _optional) when is_list(opts), do: module.new(opts)
  defp nested(map, module, _optional) when is_map(map), do: module.from_map(map)

  defp nested(value, module, _optional) do
    raise ArgumentError,
          "#{inspect(module)} config must be a struct, keyword list, or map; got: #{inspect(value)}"
  end

  defp validate_runtime!(config) do
    validate_stopper!(config.stopper)
    validate_perfect_score!(config.reflection)

    case Callback.validate(config.callbacks) do
      {:ok, _callbacks} -> :ok
      {:error, message} -> raise ArgumentError, "callbacks #{message}"
    end
  end

  defp validate_perfect_score!(%{skip_perfect_score: true, perfect_score: score})
       when not is_number(score) do
    raise ArgumentError, "perfect_score must be numeric when skip_perfect_score is true"
  end

  defp validate_perfect_score!(_reflection), do: :ok

  defp validate_stopper!(nil), do: :ok

  defp validate_stopper!(stopper) do
    Stopper.new(stopper)
    :ok
  rescue
    error in [ArgumentError, FunctionClauseError] ->
      reraise ArgumentError,
              [message: "invalid Optimize Anything stopper: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp ensure_persistable_runtime!(%{stopper: nil, callbacks: []} = config) do
    if not is_nil(config.reflection.reflection_strategy) do
      raise ArgumentError,
            "Optimize Anything reflection_strategy is runtime-only and cannot be persisted"
    end

    Persistence.json_safe!(config.reflection.reflection_lm, [:reflection, :reflection_lm])

    Persistence.json_safe!(config.reflection.custom_candidate_proposer, [
      :reflection,
      :custom_candidate_proposer
    ])

    Persistence.json_safe!(config.refiner && config.refiner.refiner_lm, [:refiner, :refiner_lm])
    Persistence.json_safe!(config.tracking.logger, [:tracking, :logger])
    :ok
  end

  defp ensure_persistable_runtime!(_config) do
    raise ArgumentError,
          "Optimize Anything stopper and callbacks are runtime-only and cannot be persisted"
  end

  defp evaluation_policy(:full_eval), do: :full
  defp evaluation_policy(policy), do: policy

  defp acceptance_policy(:improvement_or_equal), do: :equal_or_better
  defp acceptance_policy(policy), do: policy

  defp proposal_width(nil), do: nil
  defp proposal_width(:single), do: 1
  defp proposal_width({kind, count}) when kind in [:same_parent, :independent], do: count
  defp proposal_width({:pxn, parents, mutations}), do: parents * mutations

  defp cache_storage(engine) do
    case Engine.cache_mode(engine) do
      :disk -> {:disk, engine.run_dir}
      _mode -> :memory
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp add_merge(opts, nil), do: Keyword.put(opts, :use_merge, false)

  defp add_merge(opts, merge) do
    opts ++
      [
        use_merge: true,
        max_merge_invocations: merge.max_merge_invocations,
        merge_val_overlap_floor: merge.merge_val_overlap_floor,
        merge_subsample_size: merge.merge_subsample_size
      ]
  end

  defp optional_nested(map, key, module) do
    case Map.get(map, Atom.to_string(key), Map.get(map, key)) do
      nil -> nil
      value -> module.from_map(value)
    end
  end

  defp fetch!(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      true -> raise ArgumentError, "#{inspect(__MODULE__)}.from_map/1 is missing #{inspect(key)}"
    end
  end
end
