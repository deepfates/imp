defmodule Imp.Tool do
  @moduledoc """
  Tool definition for ReAct-style programs and supervised Elixir workflows.

  A tool is a named, schema-described Elixir function. ReAct programs expose
  tools to the language model, while ordinary Elixir code can call the same
  tool values directly. The name is the action, the description is written for
  the model or a human reader, the schema is the input contract, and the
  function is ordinary Elixir.

  Tool calls validate JSON-schema-shaped input contracts before invoking the
  runner, are wrapped in Imp telemetry, and runtime traces redact sensitive
  values before they are stored.

  ## Example

      iex> tool =
      ...>   Imp.Tool.new(:lookup, "lookup a capital city", fn %{country: "France"} ->
      ...>     "Paris"
      ...>   end)
      iex> Imp.Tool.call(tool, %{country: "France"})
      "Paris"
  """

  defstruct [:name, :description, :run, schema: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          description: String.t(),
          run: (map() -> term()),
          schema: map(),
          metadata: map()
        }

  @option_schema [
    schema: [type: {:map, :any, :any}, default: %{}],
    metadata: [type: {:map, :any, :any}, default: %{}]
  ]

  @doc """
  Builds a tool from a name, description, unary function, and optional schema.

  The name keeps the type it was given: an atom stays an atom and a string stays
  a string. Tools imported from an MCP server are named by the string the server
  published. A string is never turned into an atom, so a name's type does not
  depend on which atoms happen to be loaded in the VM, and no atom is created
  from a remote server's or a model's text. Lookups by name
  (`resolve_name/2`) compare atoms and strings by their text.

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
      schema: opts[:schema],
      metadata: opts[:metadata]
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
  span after validating the argument against the supported JSON Schema input
  contract. Schema validation errors are returned without invoking the runner.
  Policy checks and trace redaction remain the responsibility of the calling
  runtime.
  """
  def call(%__MODULE__{run: run} = tool, arg) do
    Imp.Telemetry.span([:imp, :tool], %{tool: tool.name, arguments: arg}, fn ->
      with :ok <- validate_input(tool, arg), do: run.(arg)
    end)
  end

  @typedoc """
  What a tool call came to, from the caller's side.

    * `:result` — the tool answered. Its answer may itself be an error the tool
      reported, such as an MCP error result; the tool said what happened.
    * `:refused` — declined before anything ran: Imp's own checks (an unknown
      tool, a malformed call, arguments that fail the schema, a tool policy, a
      host's authorization, submit outputs that do not fit), recorded by the
      loop that made them; for an MCP tool, the server or its HTTP layer; or
      an MCP error result that declares it.
    * `:auth_refused` — the credential was refused before anything ran: an
      MCP server's HTTP 401, a failed OAuth flow, or an MCP error result that
      declares it. Renewing the credential and trying once more may succeed.
    * `:not_sent` — an MCP request that never left.
    * `:unknown` — the tool may have acted and there is no answer to say
      whether it did: a tool function that raised, threw or exited, an RLM
      budget that stopped or refused the call, an MCP call with no trustworthy
      answer, or an MCP error result that declares it. Check before repeating
      it.
  """
  @type outcome :: :result | :refused | :auth_refused | :not_sent | :unknown

  @outcomes [:result, :refused, :auth_refused, :not_sent, :unknown]

  @doc "Every `t:outcome/0`."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  The outcome of a tool call, read from the value the call returned.

  Pass what `call/2` returned, or the `{:error, reason}` a ReActV2 or RLM loop
  recorded for the call. A tool function can return any term, including one
  that looks like an Imp refusal, so a value alone never reads as `:refused`
  unless something that knows declared it: an `Imp.MCP.CallFailure`, which
  Imp builds where ExMCP's error arrives, or an MCP error result whose
  `structuredContent.outcome` is `"refused"`, `"auth_refused"` or
  `"unknown"`. Imp's own refusals are decided by the loop that made them,
  which records the outcome on the call's `:tool_result` event as
  `metadata.outcome`; read that rather than this for a recorded call.

      iex> Imp.Tool.outcome("Paris")
      :result
      iex> Imp.Tool.outcome({:error, {:tool_error, :lookup, {:exit, :killed}}})
      :unknown
      iex> Imp.Tool.outcome({:error, {:mcp_tool_error, %{
      ...>   "isError" => true,
      ...>   "content" => [%{"type" => "text", "text" => "error: write outcome unknown"}],
      ...>   "structuredContent" => %{"code" => "write_outcome_unknown", "outcome" => "unknown"}
      ...> }}})
      :unknown
  """
  @spec outcome(term()) :: outcome()
  def outcome({:error, reason}), do: error_outcome(reason)
  def outcome(_value), do: :result

  # RLM runs each tool inside its budget. A budget error can come before the
  # tool starts or after RLM stopped a tool that was still running, and the
  # term does not say which, so it reads as unknown.
  @rlm_budget_errors [:rlm_time_budget_exceeded, :rlm_cancelled, :rlm_max_llm_calls]

  defp error_outcome(%Imp.MCP.CallFailure{outcome: outcome}), do: outcome
  defp error_outcome({:mcp_tool_error, envelope}), do: declared_outcome(envelope)
  defp error_outcome({:rlm_tool_error, reason}), do: error_outcome(reason)
  defp error_outcome({:rlm_effect_exit, _reason}), do: :unknown
  defp error_outcome(reason) when reason in @rlm_budget_errors, do: :unknown

  defp error_outcome(reason) when is_tuple(reason) and elem(reason, 0) in @rlm_budget_errors,
    do: :unknown

  defp error_outcome({:tool_error, _name, _reason}), do: :unknown
  defp error_outcome(_reason), do: :result

  # An MCP error result is the tool's own answer. A server that knows more
  # than that says so in `structuredContent.outcome`, in the words of this
  # type: Kite marks a write that may have been applied `"unknown"`, and its
  # `Kite.Effects.Failure` kinds are these names. Nothing else in the envelope
  # is read as a claim about whether the tool acted.
  @declared %{"refused" => :refused, "auth_refused" => :auth_refused, "unknown" => :unknown}

  defp declared_outcome(envelope) when is_map(envelope) do
    with structured when is_map(structured) <- field(envelope, :structuredContent),
         declared when is_binary(declared) <- field(structured, :outcome) do
      Map.get(@declared, declared, :result)
    else
      _none -> :result
    end
  end

  defp declared_outcome(_envelope), do: :result

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc false
  def validate_input(%__MODULE__{} = tool, input), do: do_validate_input(tool, input)

  # An empty schema declares no input contract, so every input passes. The
  # error tuples are the shape every Imp runtime already matches on, so there
  # is one validation contract and no second public validation API.
  defp do_validate_input(%__MODULE__{schema: schema}, _input) when map_size(schema) == 0,
    do: :ok

  defp do_validate_input(%__MODULE__{schema: schema}, input) do
    with :ok <- validate_root(input, schema),
         :ok <- validate_required(input, schema),
         :ok <- validate_properties(input, schema) do
      :ok
    end
  end

  defp normalize_name(name) when is_atom(name) or is_binary(name), do: name

  defp normalize_name(name) do
    raise ArgumentError,
          "Imp.Tool names must be atoms or strings; got: #{inspect(name)}"
  end

  defp safe_existing_atom(key) when is_atom(key), do: key

  defp safe_existing_atom(key) do
    String.to_existing_atom(to_string(key))
  rescue
    ArgumentError -> to_string(key)
  end

  defp validate_root(input, schema) do
    type = fetch_schema(schema, :type)

    cond do
      not is_nil(type) and not valid_type?(input, type) ->
        validation_error(:input, :type, "expected #{type}")

      object_constraints?(schema) and not is_map(input) ->
        validation_error(:input, :type, "expected object")

      true ->
        :ok
    end
  end

  defp object_constraints?(schema) do
    fetch_schema(schema, :required, :__missing__) != :__missing__ or
      fetch_schema(schema, :properties, :__missing__) != :__missing__
  end

  defp validate_required(input, schema) do
    missing =
      schema
      |> fetch_schema(:required, [])
      |> Enum.reject(&present?(input, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required, keys}}
    end
  end

  defp validate_properties(input, schema) do
    errors =
      schema
      |> fetch_schema(:properties, %{})
      |> Enum.flat_map(fn {name, property_schema} ->
        case fetch_input(input, name) do
          {:ok, value} -> validate_value(name, value, property_schema)
          :error -> []
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:schema_validation, errors}}
    end
  end

  defp validate_value(name, value, schema) do
    []
    |> validate_type(name, value, fetch_schema(schema, :type))
    |> validate_enum(name, value, fetch_schema(schema, :enum))
    |> validate_minimum(name, value, fetch_schema(schema, :minimum))
    |> validate_maximum(name, value, fetch_schema(schema, :maximum))
  end

  defp validate_type(errors, _name, _value, nil), do: errors

  defp validate_type(errors, name, value, type) do
    if valid_type?(value, type),
      do: errors,
      else: errors ++ [%{field: name, rule: :type, message: "expected #{type}"}]
  end

  defp valid_type?(value, type) do
    case type do
      type when type in ["string", :string] -> is_binary(value)
      type when type in ["integer", :integer] -> is_integer(value)
      type when type in ["number", :number] -> is_number(value)
      type when type in ["boolean", :boolean] -> is_boolean(value)
      type when type in ["array", :array] -> is_list(value)
      type when type in ["object", :object] -> is_map(value)
      _ -> true
    end
  end

  defp validate_enum(errors, _name, _value, nil), do: errors

  defp validate_enum(errors, name, value, allowed) do
    if value in allowed,
      do: errors,
      else: errors ++ [%{field: name, rule: :enum, message: "must be one of #{inspect(allowed)}"}]
  end

  defp validate_minimum(errors, _name, _value, nil), do: errors

  defp validate_minimum(errors, name, value, min) when is_number(value) and value < min,
    do: errors ++ [%{field: name, rule: :minimum, message: "must be >= #{min}"}]

  defp validate_minimum(errors, _name, _value, _min), do: errors

  defp validate_maximum(errors, _name, _value, nil), do: errors

  defp validate_maximum(errors, name, value, max) when is_number(value) and value > max,
    do: errors ++ [%{field: name, rule: :maximum, message: "must be <= #{max}"}]

  defp validate_maximum(errors, _name, _value, _max), do: errors

  defp validation_error(field, rule, message),
    do: {:error, {:schema_validation, [%{field: field, rule: rule, message: message}]}}

  defp fetch_schema(map, key, default \\ nil) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp present?(input, key),
    do: match?({:ok, value} when not is_nil(value), fetch_input(input, key))

  defp fetch_input(input, key) when is_atom(key),
    do: Map.fetch(input, key) |> or_fetch(input, Atom.to_string(key))

  defp fetch_input(input, key) when is_binary(key) do
    case Map.fetch(input, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case existing_atom(key) do
          {:ok, atom} -> Map.fetch(input, atom)
          :error -> :error
        end
    end
  end

  defp or_fetch({:ok, value}, _input, _key), do: {:ok, value}
  defp or_fetch(:error, input, key), do: Map.fetch(input, key)

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end
