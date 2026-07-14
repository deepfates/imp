defmodule Imp.Saving.Registry do
  @moduledoc """
  Immutable allowlist of named callbacks used to rebind portable program artifacts.

  Artifacts store callback names only. The deploying application constructs the
  registry from trusted functions and supplies it explicitly when dumping or loading.
  """

  defstruct callbacks: %{}

  @doc "Builds a registry from a map or enumerable of `{name, function}` pairs."
  def new(entries \\ %{}) do
    callbacks =
      entries
      |> Map.new()
      |> Map.new(fn {name, callback} ->
        unless (is_atom(name) or is_binary(name)) and is_function(callback) do
          raise ArgumentError,
                "saving registry entries require atom/string names and functions; got: #{inspect({name, callback})}"
        end

        {to_string(name), callback}
      end)

    %__MODULE__{callbacks: callbacks}
  end

  @doc false
  def key_for!(%__MODULE__{callbacks: callbacks}, callback, context) when is_function(callback) do
    Enum.find_value(callbacks, fn {name, registered} -> if registered === callback, do: name end) ||
      raise ArgumentError, "#{context} is not present in the supplied saving registry"
  end

  @doc false
  def fetch!(%__MODULE__{callbacks: callbacks}, name, arities, context) do
    callback =
      Map.get(callbacks, to_string(name)) ||
        raise ArgumentError,
              "saved #{context} references unknown registry callback #{inspect(name)}"

    unless Enum.any?(List.wrap(arities), &is_function(callback, &1)) do
      raise ArgumentError,
            "saved #{context} callback #{inspect(name)} has the wrong arity; expected #{inspect(List.wrap(arities))}"
    end

    callback
  end
end
