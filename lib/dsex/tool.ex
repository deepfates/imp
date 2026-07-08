defmodule DSEx.Tool do
  @moduledoc """
  Tool definition for ReAct-style programs and DSEx agents.

  A tool is a named, schema-described Elixir function. ReAct programs expose
  tools to the language model, while `DSEx.Agent` handlers can call the same
  tool values directly through the runtime. The useful DSEx habit is to keep the
  boundary explicit: the tool name is the action, the description is for the
  model or human reader, the schema is the input contract, and the function is
  ordinary Elixir.

  Tool calls are wrapped in DSEx telemetry and runtime traces redact sensitive
  values before they are stored.

  ## Example

      iex> tool =
      ...>   DSEx.Tool.new(:lookup, "lookup a capital city", fn %{country: "France"} ->
      ...>     "Paris"
      ...>   end)
      iex> DSEx.Tool.call(tool, %{country: "France"})
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
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Tool.new/4")

    %__MODULE__{
      name: normalize_name(name),
      description: description,
      run: run,
      schema: opts[:schema]
    }
  end

  def new(_name, _description, run, _opts) do
    raise ArgumentError,
          "DSEx.Tool.new/4 expects a unary function as the tool runner; got: #{inspect(run)}"
  end

  def validate_tools(tools) when is_list(tools) do
    case Enum.find(tools, &(not match?(%__MODULE__{}, &1))) do
      nil ->
        {:ok, tools}

      invalid ->
        {:error, "expected a list of DSEx.Tool structs, got invalid entry: #{inspect(invalid)}"}
    end
  end

  def validate_tools(tools) do
    {:error, "expected a list of DSEx.Tool structs, got: #{inspect(tools)}"}
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
  Calls a tool with one argument.

  This executes the underlying function inside a `[:dsex, :tool]` telemetry
  span. Policy checks, schema checks, and trace redaction happen in the agent or
  ReAct runtime that calls the tool.
  """
  def call(%__MODULE__{run: run} = tool, arg) do
    DSEx.Telemetry.span([:dsex, :tool], %{tool: tool.name, arguments: arg}, fn -> run.(arg) end)
  end

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: existing_atom_or_string(name)

  defp normalize_name(name) do
    raise ArgumentError,
          "DSEx.Tool names must be atoms or strings; got: #{inspect(name)}"
  end

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end
