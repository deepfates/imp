defmodule DSEx.Predict.RLM.SandboxSerializable do
  @moduledoc """
  Lazy value handle for RLM variable-space exploration.

  Use this for large or expensive inputs that should be advertised to the RLM
  controller as metadata before the full value is loaded into the sandbox state.
  Controller code loads it with `context = load("context")`.
  """

  defstruct [:name, :loader, metadata: %{}]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          loader: (-> term()),
          metadata: map()
        }

  @doc "Creates a lazy value handle for RLM inputs."
  def new(name, loader, opts \\ [])

  def new(name, loader, opts) when is_function(loader, 0) and is_list(opts) do
    %__MODULE__{
      name: name,
      loader: loader,
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }
  end

  def new(_name, loader, _opts) do
    raise ArgumentError,
          "DSEx.Predict.RLM.SandboxSerializable.new/3 expects a zero-arity loader function, got: #{inspect(loader)}"
  end

  @doc "Loads the underlying value, returning structured errors for loader failures."
  def load(%__MODULE__{loader: loader}) do
    {:ok, loader.()}
  rescue
    exception -> {:error, {:sandbox_serializable_load_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:sandbox_serializable_load_failed, {kind, reason}}}
  end
end
