defmodule Imp.Tool do
  @moduledoc """
  Tool definition for ReAct-style programs and Imp agents.

  A tool is a named, schema-described Elixir function. ReAct programs expose
  tools to the language model, while `Imp.Agent` handlers can call the same
  tool values directly through the runtime. The useful Imp habit is to keep the
  boundary explicit: the tool name is the action, the description is for the
  model or human reader, the schema is the input contract, and the function is
  ordinary Elixir.

  Tool calls are wrapped in Imp telemetry and runtime traces redact sensitive
  values before they are stored.

  ## Example

      iex> tool =
      ...>   Imp.Tool.new(:lookup, "lookup a capital city", fn %{country: "France"} ->
      ...>     "Paris"
      ...>   end)
      iex> Imp.Tool.call(tool, %{country: "France"})
      "Paris"
  """

  defstruct [:name, :description, :run, schema: %{}]

  @option_schema [
    schema: [type: {:map, :any, :any}, default: %{}]
  ]

  @doc """
  Builds a tool from a name, description, unary function, and optional schema.

  Atom names stay atoms. String names are converted to an existing atom when one
  is already loaded, otherwise they remain strings. This avoids creating atoms
  from untrusted model output while still allowing tools to round-trip provider
  payloads that use string names.

  The schema is a JSON-schema-shaped map used by ReAct/provider adapters and by
  humans reading the program boundary.
  """
  def new(name, description, run, opts \\ [])

  def new(name, description, run, opts) when is_function(run, 1) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Tool.new/4")

    %__MODULE__{
      name: normalize_name(name),
      description: description,
      run: run,
      schema: opts[:schema]
    }
  end

  def new(_name, _description, run, _opts) do
    raise ArgumentError,
          "Imp.Tool.new/4 expects a unary function as the tool runner; got: #{inspect(run)}"
  end

  def validate_tools(tools) when is_list(tools) do
    case Enum.find(tools, &(not match?(%__MODULE__{}, &1))) do
      nil ->
        {:ok, tools}

      invalid ->
        {:error, "expected a list of Imp.Tool structs, got invalid entry: #{inspect(invalid)}"}
    end
  end

  def validate_tools(tools) do
    {:error, "expected a list of Imp.Tool structs, got: #{inspect(tools)}"}
  end

  def index_tools!(tools, context) do
    case validate_tools(tools) do
      {:ok, tools} ->
        Map.new(tools, &{&1.name, &1})

      {:error, message} ->
        raise ArgumentError,
              "#{context} expects tools to be #{String.replace_prefix(message, "expected ", "")}"
    end
  end

  @doc """
  Resolves a model/provider tool name to the canonical name in a tool catalog.

  Provider payloads commonly send names as strings, while Elixir code usually
  stores tool names as atoms. This helper performs string-equivalent lookup
  without creating atoms from model output.

      iex> tools = [Imp.Tool.new(:lookup, "lookup", fn _ -> :ok end)]
      iex> catalog = Imp.Tool.index_tools!(tools, "example")
      iex> Imp.Tool.resolve_name(catalog, "lookup")
      :lookup
      iex> Imp.Tool.resolve_name(catalog, "missing")
      nil
  """
  def resolve_name(tools, name) when is_map(tools) do
    Enum.find_value(Map.keys(tools), fn known ->
      if to_string(known) == to_string(name), do: known
    end)
  end

  @doc """
  Normalizes model/provider tool arguments into the Imp tool-call shape.

  JSON string arguments are decoded. Map keys become existing atoms when the
  atom is already loaded and stay strings otherwise, avoiding atom leaks from
  untrusted model output while keeping idiomatic Elixir tool functions pleasant.

      iex> Imp.Tool.normalize_arguments(~s({"query":"capital"}))
      %{query: "capital"}
  """
  def normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> normalize_arguments(decoded)
      {:error, _reason} -> arguments
    end
  end

  def normalize_arguments(arguments) when is_map(arguments),
    do: Map.new(arguments, fn {key, value} -> {safe_existing_atom(key), value} end)

  def normalize_arguments(arguments), do: arguments

  @doc """
  Calls a tool with one argument.

  This executes the underlying function inside a `[:imp, :tool]` telemetry
  span. Policy checks, schema checks, and trace redaction happen in the agent or
  ReAct runtime that calls the tool.
  """
  def call(%__MODULE__{run: run} = tool, arg) do
    Imp.Telemetry.span([:imp, :tool], %{tool: tool.name, arguments: arg}, fn -> run.(arg) end)
  end

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: existing_atom_or_string(name)

  defp normalize_name(name) do
    raise ArgumentError,
          "Imp.Tool names must be atoms or strings; got: #{inspect(name)}"
  end

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp safe_existing_atom(key) when is_atom(key), do: key

  defp safe_existing_atom(key) do
    String.to_existing_atom(to_string(key))
  rescue
    ArgumentError -> to_string(key)
  end
end
