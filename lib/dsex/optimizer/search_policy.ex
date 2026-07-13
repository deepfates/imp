defmodule DSEx.Optimizer.SearchPolicy do
  @moduledoc false

  @type context :: term()
  @type observation :: term()
  @type state :: term()

  @callback id() :: String.t()
  @callback new(keyword()) :: state()
  @callback suggest(state(), context()) :: {term(), state()}
  @callback observe(state(), observation()) :: state()
  @callback dump(state()) :: map()
  @callback load!(map()) :: state()

  @schema_version 1
  @policies [
    DSEx.Optimizer.SearchPolicy.CategoricalTPE,
    DSEx.Optimizer.SearchPolicy.Sampling
  ]

  @enforce_keys [:module, :state]
  defstruct [:module, :state]

  @type t :: %__MODULE__{module: module(), state: state()}

  @spec new(module(), keyword()) :: t()
  def new(module, opts \\ []) when is_atom(module) and is_list(opts) do
    ensure_policy!(module)
    %__MODULE__{module: module, state: module.new(opts)}
  end

  @spec suggest(t(), context()) :: {term(), t()}
  def suggest(%__MODULE__{module: module, state: state} = policy, context) do
    {suggestion, state} = module.suggest(state, context)
    {suggestion, %{policy | state: state}}
  end

  @spec observe(t(), observation()) :: t()
  def observe(%__MODULE__{module: module, state: state} = policy, observation) do
    %{policy | state: module.observe(state, observation)}
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{module: module, state: state}) do
    ensure_policy!(module)

    %{
      "schema_version" => @schema_version,
      "policy" => module.id(),
      "state" => module.dump(state)
    }
  end

  @spec load!(map(), [module()]) :: t()
  def load!(checkpoint, policies \\ @policies)

  def load!(%{"schema_version" => @schema_version, "policy" => id, "state" => state}, policies)
      when is_binary(id) and is_map(state) do
    Enum.each(policies, &ensure_policy!/1)
    module = Enum.find(policies, &(&1.id() == id))

    if module do
      %__MODULE__{module: module, state: module.load!(state)}
    else
      raise ArgumentError, "unknown optimizer search policy: #{inspect(id)}"
    end
  end

  def load!(value, _policies),
    do: raise(ArgumentError, "invalid optimizer search policy checkpoint: #{inspect(value)}")

  defp ensure_policy!(module) do
    callbacks = [id: 0, new: 1, suggest: 2, observe: 2, dump: 1, load!: 1]

    unless Code.ensure_loaded?(module) and
             Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      raise ArgumentError, "invalid optimizer search policy module: #{inspect(module)}"
    end
  end
end
