defmodule Imp.ACP.Options do
  @moduledoc false

  defstruct [
    :program_factory,
    :input_key,
    :input_mapper,
    :output_key,
    :output_renderer,
    :cleanup,
    :session_store,
    tool_kinds: %{},
    permission_policy: :client,
    authorization_timeout: 3_600_000,
    cancel_timeout: 5_000
  ]

  @type t :: %__MODULE__{}

  def new(opts) when is_list(opts) do
    program_factory = program_factory!(opts)
    input_mapper = optional_fun!(opts, :input_mapper, 2)
    output_renderer = optional_fun!(opts, :output_renderer, 2)
    cleanup = optional_fun!(opts, :cleanup, 1)
    session_store = session_store!(opts)
    permission_policy = Keyword.get(opts, :permission_policy, :client)
    authorization_timeout = Keyword.get(opts, :authorization_timeout, 3_600_000)
    cancel_timeout = Keyword.get(opts, :cancel_timeout, 5_000)
    tool_kinds = tool_kinds!(opts)

    unless permission_policy in [:client, :unrestricted] or
             is_function(permission_policy, 1) or is_function(permission_policy, 2) do
      raise ArgumentError,
            ":permission_policy must be :client, :unrestricted, or a function of arity 1 or 2"
    end

    unless is_integer(authorization_timeout) and authorization_timeout > 0 do
      raise ArgumentError, ":authorization_timeout must be a positive integer"
    end

    unless is_integer(cancel_timeout) and cancel_timeout > 0 do
      raise ArgumentError, ":cancel_timeout must be a positive integer"
    end

    %__MODULE__{
      program_factory: program_factory,
      input_key: Keyword.get(opts, :input_key),
      input_mapper: input_mapper,
      output_key: Keyword.get(opts, :output_key),
      output_renderer: output_renderer,
      cleanup: cleanup,
      session_store: session_store,
      tool_kinds: tool_kinds,
      permission_policy: permission_policy,
      authorization_timeout: authorization_timeout,
      cancel_timeout: cancel_timeout
    }
  end

  @acp_tool_kinds ~w(read edit delete move search execute think fetch switch_mode other)

  @doc "ACP tool kinds accepted in `:tool_kinds`."
  def acp_tool_kinds, do: @acp_tool_kinds

  # Imp tools carry no ACP kind, and the session falls back to a name-based
  # guess that classifies everything unfamiliar as "other". Hosts such as Haven
  # apply permission modes by kind (reads pass, mutations ask or are denied),
  # so an agent declares the kind of each of its tools here.
  #
  # An MCP tool declares its own nature instead, and `Imp.ACP.ToolKind` derives
  # the kind from that declaration; a program factory hands those derived kinds
  # back with its program. This option remains the way to name a kind that
  # annotations cannot express, and it outranks anything derived.
  defp tool_kinds!(opts) do
    case validate_tool_kinds(Keyword.get(opts, :tool_kinds, %{})) do
      {:ok, kinds} ->
        kinds

      {:error, {:invalid_tool_kind, name, kind}} ->
        raise ArgumentError,
              ":tool_kinds values must be ACP tool kinds #{inspect(@acp_tool_kinds)}, " <>
                "got #{inspect(kind)} for #{inspect(name)}"

      {:error, {:invalid_tool_kinds, other}} ->
        raise ArgumentError,
              ":tool_kinds must be a map of tool name to ACP kind, got: #{inspect(other)}"
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

      # A host application that already knows what its client should be told
      # returns a JSON-RPC error triple. Tagging it as a lifecycle failure would
      # bury the one thing about it that is useful, so it passes through.
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

  def extract_history(%Imp.Prediction{} = prediction, previous) do
    Imp.Prediction.get(prediction, :history, previous)
  end

  defp program_factory!(opts) do
    case {Keyword.get(opts, :program), Keyword.get(opts, :program_factory)} do
      {nil, factory} when is_function(factory, 1) ->
        factory

      {%_{} = program, nil} ->
        fn _session -> program end

      {nil, nil} ->
        raise ArgumentError, "expected :program or :program_factory"

      {_program, _factory} ->
        raise ArgumentError, "pass either :program or :program_factory, not both"
    end
  end

  defp optional_fun!(opts, key, arity) do
    case Keyword.get(opts, key) do
      nil -> nil
      fun when is_function(fun, arity) -> fun
      _ -> raise ArgumentError, ":#{key} must be a function of arity #{arity}"
    end
  end

  defp session_store!(opts) do
    case Keyword.get(opts, :session_store) do
      nil -> nil
      path when is_binary(path) and path != "" -> Path.expand(path)
      _other -> raise ArgumentError, ":session_store must be a non-empty path"
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
