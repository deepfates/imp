defmodule Imp.Optimize.Anything.StructuredStrategy do
  @moduledoc """
  A checkpoint-safe mutation strategy for native structured Optimize Anything artifacts.

  A strategy receives the complete native artifact, reflective evaluation data,
  and the top-level components selected for this proposal. It returns a complete
  replacement artifact. Imp validates the exact seed-derived shape and value
  types and rejects changes outside the selected components before the shared
  GEPA engine sees an internal representation.

  Strategies are configured with a stable, consumer-owned version identifier:

      strategy =
        Imp.Optimize.Anything.StructuredStrategy.new(MyArtifactStrategy,
          id: "routing-policy/v1",
          config: %{"max_retries" => 3}
        )

      config =
        Imp.Optimize.Anything.Config.new(
          engine: [max_candidate_proposals: 4],
          reflection: [structured_strategy: strategy]
        )

  The strategy module must implement `propose/4`. Configuration is restricted
  to JSON-native data so checkpoints never serialize executable code or create
  atoms dynamically.
  """

  alias Imp.Optimize.Anything.StructuredCandidate
  alias Imp.Optimizer.GEPA.ReflectionStrategy

  @enforce_keys [:module, :id, :config, :identity]
  defstruct [:module, :id, :config, :identity]

  @type artifact :: map()
  @type reflective_dataset :: map()
  @type component :: atom() | String.t()
  @type proposal ::
          {:ok, artifact()}
          | {:ok, artifact(), map()}
          | {:error, term()}
          | artifact()

  @type t :: %__MODULE__{
          module: module(),
          id: String.t(),
          config: map() | list() | String.t() | number() | boolean() | nil,
          identity: String.t()
        }

  @callback propose(artifact(), reflective_dataset(), [component()], term()) :: proposal()

  @doc "Creates a native structured-artifact strategy with stable resume identity."
  @spec new(module(), keyword()) :: t()
  def new(module, opts) when is_atom(module) and is_list(opts) do
    unknown = Keyword.keys(opts) -- [:id, :config]

    if unknown != [] do
      raise ArgumentError, "unknown structured strategy options: #{inspect(unknown)}"
    end

    id = Keyword.get(opts, :id)
    config = Keyword.get(opts, :config, %{})

    unless is_binary(id) and String.trim(id) != "" do
      raise ArgumentError, "structured strategy :id must be a non-empty versioned string"
    end

    validate_module!(module)
    validate_json_native!(config, [:config])
    identity = digest({Atom.to_string(module), id, config})
    %__MODULE__{module: module, id: id, config: config, identity: identity}
  end

  def new(module, opts) do
    raise ArgumentError,
          "StructuredStrategy.new/2 expects a module and keyword options, got: #{inspect({module, opts})}"
  end

  @doc "Returns the stable module/id/config identity bound into checkpoints."
  @spec identity(t()) :: String.t()
  def identity(%__MODULE__{identity: identity}), do: identity

  @doc "Returns a versioned JSON-safe representation of the strategy binding."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = strategy) do
    %{
      "type" => "imp_optimize_anything_structured_strategy",
      "schema_version" => 1,
      "module" => Atom.to_string(strategy.module),
      "id" => strategy.id,
      "config" => strategy.config,
      "identity" => strategy.identity
    }
  end

  @doc "Restores a strategy binding without creating module atoms dynamically."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    unless fetch(map, :type) == "imp_optimize_anything_structured_strategy" and
             fetch(map, :schema_version) == 1 do
      raise ArgumentError, "invalid structured strategy persistence envelope"
    end

    module_name = fetch(map, :module)

    unless is_binary(module_name) do
      raise ArgumentError, "structured strategy module identity must be a string"
    end

    module =
      try do
        String.to_existing_atom(module_name)
      rescue
        ArgumentError ->
          reraise ArgumentError,
                  [message: "structured strategy module is not already loaded"],
                  __STACKTRACE__
      end

    strategy = new(module, id: fetch(map, :id), config: fetch(map, :config))

    unless strategy.identity == fetch(map, :identity) do
      raise ArgumentError, "structured strategy identity does not match its module/id/config"
    end

    strategy
  end

  def from_map(value) do
    raise ArgumentError, "structured strategy persistence must be a map, got: #{inspect(value)}"
  end

  @doc false
  def validate!(nil), do: nil
  def validate!(%__MODULE__{} = strategy), do: from_map(to_map(strategy))

  def validate!(value) do
    raise ArgumentError,
          "structured_strategy must be an Imp.Optimize.Anything.StructuredStrategy, got: #{inspect(value)}"
  end

  @doc false
  def bridge(%__MODULE__{} = strategy, %StructuredCandidate{} = codec) do
    ReflectionStrategy.contextual(__MODULE__.Bridge, %{strategy: strategy, codec: codec})
  end

  defp validate_module!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :propose, 4) do
      raise ArgumentError, "structured strategy module must export propose/4"
    end
  end

  defp validate_json_native!(nil, _path), do: :ok

  defp validate_json_native!(value, _path)
       when is_binary(value) or is_boolean(value) or is_number(value),
       do: :ok

  defp validate_json_native!(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> validate_json_native!(value, [index | path]) end)
  end

  defp validate_json_native!(map, path) when is_map(map) and not is_struct(map) do
    Enum.each(map, fn {key, value} ->
      unless is_binary(key) do
        invalid_config!(path, "map keys must be strings, got #{inspect(key)}")
      end

      validate_json_native!(value, [key | path])
    end)
  end

  defp validate_json_native!(value, path),
    do: invalid_config!(path, "contains non-JSON value #{inspect(value)}")

  defp invalid_config!(path, message) do
    rendered = path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)
    raise ArgumentError, "structured strategy #{rendered} #{message}"
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end

defmodule Imp.Optimize.Anything.StructuredStrategy.Bridge do
  @moduledoc false

  alias Imp.Optimize.Anything.{StructuredCandidate, StructuredStrategy}

  def reflect(
        encoded_candidate,
        dataset,
        components,
        %{strategy: strategy, codec: codec} = context
      ) do
    candidate = StructuredCandidate.decode_candidate!(codec, encoded_candidate)

    strategy.module
    |> apply(:propose, [candidate, dataset, components, strategy.config])
    |> normalize(candidate, encoded_candidate, components, codec, context)
  end

  def dump_state(%{strategy: strategy, codec: codec}) do
    %{
      "strategy" => StructuredStrategy.to_map(strategy),
      "codec" => StructuredCandidate.to_map(codec)
    }
  end

  def load_state(%{"strategy" => strategy, "codec" => codec}) do
    %{strategy: StructuredStrategy.from_map(strategy), codec: StructuredCandidate.from_map(codec)}
  end

  def load_state(value) do
    raise ArgumentError, "invalid structured strategy checkpoint state: #{inspect(value)}"
  end

  defp normalize({:error, reason}, _candidate, _encoded, _components, _codec, _context),
    do: {:error, reason}

  defp normalize({:ok, proposal}, candidate, encoded, components, codec, context),
    do: proposal(proposal, %{}, candidate, encoded, components, codec, context)

  defp normalize({:ok, proposal, metadata}, candidate, encoded, components, codec, context)
       when is_map(metadata),
       do: proposal(proposal, metadata, candidate, encoded, components, codec, context)

  defp normalize(proposal, candidate, encoded, components, codec, context) when is_map(proposal),
    do: proposal(proposal, %{}, candidate, encoded, components, codec, context)

  defp normalize(value, _candidate, _encoded, _components, _codec, _context),
    do: {:error, {:invalid_structured_strategy_result, value}}

  defp proposal(proposed, metadata, _candidate, encoded, components, codec, context) do
    proposed_encoded = StructuredCandidate.encode_candidate!(codec, proposed)

    changed =
      proposed_encoded
      |> Enum.filter(fn {key, value} -> Map.fetch!(encoded, key) != value end)
      |> Enum.map(&elem(&1, 0))

    allowed = MapSet.new(components)
    unselected = Enum.reject(changed, &MapSet.member?(allowed, &1))

    cond do
      changed == [] ->
        {:error, :no_op_structured_strategy_candidate}

      unselected != [] ->
        {:error, {:structured_strategy_changed_unselected_components, unselected}}

      true ->
        new_texts = Map.take(proposed_encoded, changed)
        {%{new_texts: new_texts, metadata: metadata}, context}
    end
  rescue
    error in ArgumentError ->
      {:error, {:invalid_structured_strategy_candidate, Exception.message(error)}}
  end
end
