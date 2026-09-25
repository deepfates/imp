defmodule Imp.ACP.Options do
  @moduledoc false

  defstruct [
    :program_factory,
    :input_key,
    :input_mapper,
    :output_key,
    :output_renderer,
    :cleanup,
    :on_cancel,
    :session_store,
    tool_kinds: %{},
    permission_policy: :client,
    authorization_timeout: 3_600_000,
    cancel_timeout: 5_000
  ]

  @type t :: %__MODULE__{}

  @acp_tool_kinds ~w(read edit delete move search execute think fetch switch_mode other)

  @schema [
    program: [
      type: {:custom, __MODULE__, :validate_program, []},
      doc:
        "An `Imp.Module` struct installed into every session. Convenient for an " <>
          "immutable program; use `:program_factory` for anything with state."
    ],
    program_factory: [
      type: {:fun, 1},
      doc:
        "Builds each session's program from the session map (see above). Returns " <>
          "the program, `{:ok, program}`, `{:ok, program, cleanup}` with a 0-arity " <>
          "cleanup function, `{:ok, program, lifecycle}` with a map of 0-arity " <>
          "`:before_turn`, `:after_turn` and `:cleanup` functions and `:tool_kinds`, " <>
          "or `{:error, reason}`. Pass exactly one of `:program` " <>
          "and `:program_factory`."
    ],
    input_key: [
      type: {:or, [:atom, :string]},
      doc:
        "The program input the prompt text goes to. When absent, the signature's " <>
          "only input."
    ],
    input_mapper: [
      type: {:or, [{:fun, 2}, nil]},
      doc: "`fn prompt, context -> inputs end`, in place of `:input_key`."
    ],
    output_key: [
      type: {:or, [:atom, :string]},
      doc:
        "The prediction field that becomes the response. When absent, the " <>
          "signature's only output."
    ],
    output_renderer: [
      type: {:or, [{:fun, 2}, nil]},
      doc: "`fn prediction, context -> text end`, in place of `:output_key`."
    ],
    cleanup: [
      type: {:or, [{:fun, 1}, nil]},
      doc:
        "`fn program -> _ end`, called with the session's program when the " <>
          "session closes; its return value is ignored."
    ],
    on_cancel: [
      type: {:or, [{:fun, 2}, nil]},
      doc:
        "`fn program, session_metadata -> :ok end`, for an explicit " <>
          "`session/cancel` only (see above)."
    ],
    session_store: [
      type: {:custom, __MODULE__, :validate_session_store, []},
      doc:
        "A directory that keeps each session's history and transcript, which " <>
          "enables `session/load`, `list`, `resume` and `delete`."
    ],
    permission_policy: [
      type: {:or, [{:in, [:client, :unrestricted]}, {:fun, 1}, {:fun, 2}]},
      default: :client,
      doc:
        "Who decides a ReActV2 or RLM tool call: `:client` asks the ACP client, " <>
          "`:unrestricted` asks no one, and a function of the request (and the " <>
          "session context) returns `:allow`, `:client` or `{:deny, reason}`."
    ],
    authorization_timeout: [
      type: :pos_integer,
      default: 3_600_000,
      doc: "Milliseconds a permission decision may take before it is a denial."
    ],
    cancel_timeout: [
      type: :pos_integer,
      default: 5_000,
      doc: "Milliseconds a cancelled turn's effects have to end."
    ],
    tool_kinds: [
      type: {:custom, __MODULE__, :validate_tool_kinds_option, []},
      default: %{},
      doc:
        "Map of tool name to ACP tool kind (#{Enum.map_join(@acp_tool_kinds, ", ", &"`#{&1}`")}), " <>
          "for tools whose kind their MCP annotations do not give; it outranks a " <>
          "kind derived from them."
    ]
  ]

  @doc false
  def schema, do: @schema

  def new(opts) when is_list(opts) do
    opts = Imp.Options.validate!(opts, @schema, "Imp.ACP")

    %__MODULE__{
      program_factory: program_factory!(opts),
      input_key: opts[:input_key],
      input_mapper: opts[:input_mapper],
      output_key: opts[:output_key],
      output_renderer: opts[:output_renderer],
      cleanup: opts[:cleanup],
      on_cancel: opts[:on_cancel],
      session_store: opts[:session_store],
      tool_kinds: opts[:tool_kinds],
      permission_policy: opts[:permission_policy],
      authorization_timeout: opts[:authorization_timeout],
      cancel_timeout: opts[:cancel_timeout]
    }
  end

  @doc false
  def validate_program(%_{} = program), do: {:ok, program}
  def validate_program(other), do: {:error, "expected a program struct, got: #{inspect(other)}"}

  @doc false
  def validate_session_store(path) when is_binary(path) and path != "",
    do: {:ok, Path.expand(path)}

  def validate_session_store(nil), do: {:ok, nil}
  def validate_session_store(_other), do: {:error, "must be a non-empty path"}

  @doc "ACP tool kinds accepted in `:tool_kinds`."
  def acp_tool_kinds, do: @acp_tool_kinds

  # Imp tools carry no ACP kind, and the session otherwise falls back to a
  # name-based guess that classifies anything unfamiliar as "other". Hosts
  # apply permission modes by kind (reads pass, mutations ask or are denied),
  # so an agent declares the kind of each of its tools here. MCP tools are
  # derived from their annotations by `Imp.ACP.ToolKind` instead; this option
  # names a kind annotations cannot express and outranks anything derived.
  @doc false
  def validate_tool_kinds_option(kinds) do
    case validate_tool_kinds(kinds) do
      {:ok, kinds} ->
        {:ok, kinds}

      {:error, {:invalid_tool_kind, name, kind}} ->
        {:error,
         "values must be ACP tool kinds #{inspect(@acp_tool_kinds)}, " <>
           "got #{inspect(kind)} for #{inspect(name)}"}

      {:error, {:invalid_tool_kinds, other}} ->
        {:error, "must be a map of tool name to ACP kind, got: #{inspect(other)}"}
    end
  end

  @doc """
  Normalizes a tool name to ACP kind map, whether it was declared as an option
  or derived from MCP tool annotations by a program factory.
  """
  @spec validate_tool_kinds(term()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def validate_tool_kinds(kinds) when is_map(kinds) do
    Enum.reduce_while(kinds, {:ok, %{}}, fn {name, kind}, {:ok, acc} ->
      kind = to_string(kind)

      if kind in @acp_tool_kinds do
        {:cont, {:ok, Map.put(acc, to_string(name), kind)}}
      else
        {:halt, {:error, {:invalid_tool_kind, name, kind}}}
      end
    end)
  end

  def validate_tool_kinds(other), do: {:error, {:invalid_tool_kinds, other}}

  # A program factory learns a session's MCP tool kinds only after it connects
  # that session's servers, which is long after the adapter's own options were
  # built. It hands them back with the program; the option map, declared by
  # name, still wins where both speak about one tool.
  @doc false
  def factory_tool_kinds(lifecycle) when is_map(lifecycle),
    do: Map.get(lifecycle, :tool_kinds, %{})

  def factory_tool_kinds(_lifecycle), do: %{}

  defp valid_lifecycle?(lifecycle) do
    Enum.all?(lifecycle, fn
      {:tool_kinds, kinds} -> is_map(kinds)
      {key, callback} -> key in [:before_turn, :after_turn, :cleanup] and is_function(callback, 0)
    end)
  end

  def build_program(%__MODULE__{program_factory: factory}, session) do
    case factory.(session) do
      {:ok, %_{} = program, lifecycle} when is_map(lifecycle) ->
        with true <- valid_lifecycle?(lifecycle),
             {:ok, kinds} <- validate_tool_kinds(Map.get(lifecycle, :tool_kinds, %{})) do
          {:ok, program, Map.put(lifecycle, :tool_kinds, kinds)}
        else
          _ -> {:error, :invalid_factory_lifecycle}
        end

      {:ok, %_{} = program, cleanup} when is_function(cleanup, 0) ->
        {:ok, program, cleanup}

      {:ok, %_{} = program} ->
        {:ok, program, nil}

      %_{} = program ->
        {:ok, program, nil}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_program_factory_result, shape(other)}}
    end
  rescue
    exception -> {:error, {:program_factory_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:program_factory_failed, {kind, reason}}}
  end

  def inputs(%__MODULE__{input_mapper: mapper}, program, prompt, context)
      when is_function(mapper, 2) do
    normalize_inputs(mapper.(prompt, Map.put(context, :program, program)))
  rescue
    exception -> {:error, {:input_mapper_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:input_mapper_failed, {kind, reason}}}
  end

  def inputs(%__MODULE__{} = options, program, prompt, context) do
    with {:ok, text} <- Imp.ACP.Prompt.text(prompt),
         {:ok, key} <- input_key(options, program) do
      inputs = %{key => text}

      if context[:history] && accepts_history?(program) do
        {:ok, Map.put(inputs, :history, context.history)}
      else
        {:ok, inputs}
      end
    end
  end

  def render(%__MODULE__{output_renderer: renderer}, prediction, context)
      when is_function(renderer, 2) do
    normalize_rendered(renderer.(prediction, context))
  rescue
    exception -> {:error, {:output_renderer_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:output_renderer_failed, {kind, reason}}}
  end

  def render(%__MODULE__{} = options, %Imp.Prediction{} = prediction, context) do
    program = context.program

    with {:ok, selected} <- select_output(options, program, prediction),
         {:ok, text} <- encode_output(selected) do
      {:ok, text}
    end
  end

  def cleanup(%__MODULE__{cleanup: cleanup}, program) when is_function(cleanup, 1) do
    safe_cleanup(fn -> cleanup.(program) end)
  end

  def cleanup(%__MODULE__{}, %module{} = program) do
    if function_exported?(module, :close, 1) do
      safe_cleanup(fn -> module.close(program) end)
    else
      :ok
    end
  end

  def cleanup_factory(nil), do: :ok

  def cleanup_factory(lifecycle) when is_map(lifecycle),
    do: lifecycle_callback(lifecycle, :cleanup)

  def cleanup_factory(cleanup) when is_function(cleanup, 0) do
    safe_cleanup(cleanup)
  end

  @doc false
  def before_turn(lifecycle) when is_map(lifecycle) do
    case Map.get(lifecycle, :before_turn, fn -> :ok end).() do
      :ok ->
        :ok

      # A JSON-RPC error triple is the host's own message to its client, so it
      # passes through instead of being wrapped as a lifecycle failure.
      {:error, {code, message, _data} = acp_error}
      when is_integer(code) and is_binary(message) ->
        {:error, acp_error}

      {:error, reason} ->
        {:error, {:before_turn_failed, reason}}

      _ ->
        {:error, :invalid_before_turn_result}
    end
  rescue
    _ -> {:error, :before_turn_failed}
  catch
    _, _ -> {:error, :before_turn_failed}
  end

  def before_turn(_), do: :ok

  @doc false
  def after_turn(lifecycle) when is_map(lifecycle),
    do: lifecycle_callback(lifecycle, :after_turn)

  def after_turn(_), do: :ok

  defp lifecycle_callback(lifecycle, key) do
    case Map.get(lifecycle, key) do
      nil -> :ok
      callback -> safe_cleanup(callback)
    end
  end

  def permission(%__MODULE__{permission_policy: :client}, _request, _context), do: :client
  def permission(%__MODULE__{permission_policy: :unrestricted}, _request, _context), do: :allow

  def permission(%__MODULE__{permission_policy: policy}, request, context)
      when is_function(policy, 2) do
    normalize_permission(policy.(request, context))
  rescue
    exception -> {:deny, {:permission_policy_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:deny, {:permission_policy_failed, {kind, reason}}}
  end

  def permission(%__MODULE__{permission_policy: policy}, request, _context)
      when is_function(policy, 1) do
    normalize_permission(policy.(request))
  rescue
    exception -> {:deny, {:permission_policy_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:deny, {:permission_policy_failed, {kind, reason}}}
  end

  def extract_history(%Imp.Prediction{metadata: metadata}, previous) do
    Map.get(metadata, :history, previous)
  end

  defp program_factory!(opts) do
    case {opts[:program], opts[:program_factory]} do
      {nil, factory} when is_function(factory, 1) -> factory
      {%_{} = program, nil} -> fn _session -> program end
      {nil, nil} -> raise ArgumentError, "Imp.ACP: expected :program or :program_factory"
      _both -> raise ArgumentError, "Imp.ACP: pass either :program or :program_factory, not both"
    end
  end

  defp normalize_inputs({:ok, inputs}) when is_map(inputs) or is_list(inputs), do: {:ok, inputs}
  defp normalize_inputs(inputs) when is_map(inputs) or is_list(inputs), do: {:ok, inputs}
  defp normalize_inputs({:error, reason}), do: {:error, reason}
  defp normalize_inputs(other), do: {:error, {:invalid_input_mapper_result, shape(other)}}

  defp normalize_rendered({:ok, text}) when is_binary(text), do: {:ok, text}
  defp normalize_rendered(text) when is_binary(text), do: {:ok, text}
  defp normalize_rendered({:error, reason}), do: {:error, reason}
  defp normalize_rendered(other), do: {:error, {:invalid_output_renderer_result, shape(other)}}

  defp normalize_permission(decision) when decision in [:allow, :client], do: decision
  defp normalize_permission({:deny, _reason} = decision), do: decision
  defp normalize_permission(other), do: {:deny, {:invalid_permission_policy_result, shape(other)}}

  defp input_key(%__MODULE__{input_key: key}, _program)
       when not is_nil(key) and (is_atom(key) or is_binary(key)),
       do: {:ok, key}

  defp input_key(%__MODULE__{}, program) do
    case signature_names(program, :input_names) do
      [key] -> {:ok, key}
      [] -> {:error, :program_has_no_signature_inputs}
      names -> {:error, {:ambiguous_program_inputs, names}}
    end
  end

  defp select_output(%__MODULE__{output_key: key}, _program, prediction)
       when not is_nil(key) and (is_atom(key) or is_binary(key)) do
    case fetch_prediction(prediction, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_output, key}}
    end
  end

  defp select_output(%__MODULE__{}, program, prediction) do
    names = signature_names(program, :output_names)

    cond do
      length(names) == 1 ->
        [key] = names

        case fetch_prediction(prediction, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:missing_output, key}}
        end

      names != [] ->
        {:ok, Map.new(names, fn key -> {key, Imp.Prediction.get(prediction, key)} end)}

      true ->
        fields = Imp.Prediction.to_map(prediction)

        case preferred_output(fields) do
          {:ok, value} -> {:ok, value}
          :error when map_size(fields) == 1 -> {:ok, fields |> Map.values() |> hd()}
          :error -> {:ok, fields}
        end
    end
  end

  defp signature_names(%{signature: %Imp.Signature{} = signature}, function) do
    apply(Imp.Signature, function, [signature])
  end

  defp signature_names(_program, _function), do: []

  defp accepts_history?(%Imp.Predict.ReActV2{}), do: true

  defp accepts_history?(program) do
    :history in signature_names(program, :input_names) or
      "history" in signature_names(program, :input_names)
  end

  defp fetch_prediction(prediction, key) do
    fields = Imp.Prediction.to_map(prediction)

    cond do
      Map.has_key?(fields, key) ->
        Map.fetch(fields, key)

      is_atom(key) and Map.has_key?(fields, Atom.to_string(key)) ->
        Map.fetch(fields, Atom.to_string(key))

      (is_binary(key) and existing_atom(key)) && Map.has_key?(fields, existing_atom(key)) ->
        Map.fetch(fields, existing_atom(key))

      true ->
        :error
    end
  end

  defp preferred_output(fields) do
    Enum.find_value(
      [:answer, "answer", :output, "output", :response, "response", :result, "result"],
      :error,
      fn key ->
        if Map.has_key?(fields, key), do: {:ok, Map.fetch!(fields, key)}
      end
    )
  end

  defp encode_output(value) when is_binary(value), do: {:ok, value}
  defp encode_output(nil), do: {:ok, ""}

  defp encode_output(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:ok, to_string(value)}
    end
  rescue
    Protocol.UndefinedError -> {:error, {:unrenderable_output, shape(value)}}
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  @doc false
  def cancel(%__MODULE__{on_cancel: nil}, _program, _metadata), do: :ok

  def cancel(%__MODULE__{on_cancel: callback}, program, metadata) do
    case callback.(program, metadata) do
      :ok -> :ok
      _ -> {:error, :cancel_callback_failed}
    end
  rescue
    _ -> {:error, :cancel_callback_failed}
  catch
    _, _ -> {:error, :cancel_callback_failed}
  end

  defp safe_cleanup(fun) do
    _ = fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
