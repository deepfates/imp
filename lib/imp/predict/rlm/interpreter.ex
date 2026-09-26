defmodule Imp.Predict.RLM.Interpreter do
  @moduledoc false

  defmodule Continuation do
    @moduledoc false
    @enforce_keys [:interpreter, :source, :results, :request]
    defstruct [:interpreter, :source, :results, :request]
  end

  defmodule Effect do
    @moduledoc false
    @enforce_keys [:kind, :name, :arguments]
    defstruct [:kind, :name, :arguments]
  end

  defmodule Fn do
    @moduledoc false
    # An anonymous function written by controller code: its clauses stay AST
    # and run through the interpreter, so a library function that calls it
    # never runs code the interpreter did not evaluate.
    @enforce_keys [:arity, :clauses]
    defstruct [:arity, :clauses]
  end

  @default_max_steps 10_000
  @default_max_output_chars 8_000
  @default_max_source_bytes 32_000
  @default_max_value_bytes 16_000_000
  @default_max_effects 100

  @binary_operators [
    :+,
    :-,
    :*,
    :/,
    :div,
    :rem,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :<=,
    :>,
    :>=,
    :<>,
    :++,
    :--,
    :and,
    :or,
    :&&,
    :||,
    :in
  ]
  @unary_operators [:+, :-, :!, :not]

  # Controller code may call every public function of these modules except
  # the refused ones below. They are pure apart from the functions they are
  # given, and those are interpreter functions (`Fn`), which cannot reach an
  # effect. A map may not pose as a struct (see `check_library_argument/2`),
  # so protocol dispatch inside these modules reaches only plain data.
  @library_modules %{Enum: Enum, Keyword: Keyword, List: List, Map: Map, String: String}
  # Kernel functions of plain data a model calls without a module: type
  # checks, sizes, tuple access, arithmetic. Nothing that makes atoms, sends,
  # spawns or reaches the process.
  @kernel_functions MapSet.new([
                      {:elem, 2},
                      {:to_string, 1},
                      {:is_map, 1},
                      {:is_list, 1},
                      {:is_binary, 1},
                      {:is_integer, 1},
                      {:is_float, 1},
                      {:is_number, 1},
                      {:is_boolean, 1},
                      {:is_atom, 1},
                      {:is_tuple, 1},
                      {:is_nil, 1},
                      {:length, 1},
                      {:map_size, 1},
                      {:tuple_size, 1},
                      {:byte_size, 1},
                      {:abs, 1},
                      {:round, 1},
                      {:trunc, 1},
                      {:div, 2},
                      {:rem, 2},
                      {:max, 2},
                      {:min, 2}
                    ])
  @refused_functions %{
    # Atoms are never garbage-collected; generated code must not mint them.
    {:String, :to_atom} => "creates atoms",
    {:List, :to_atom} => "creates atoms",
    # A lazy stream carries native closures into the variable space.
    {:String, :splitter} => "returns a lazy stream",
    # These read and advance the process's random state, so a repaired cell
    # would not recompute the same value.
    {:Enum, :random} => "is nondeterministic",
    {:Enum, :shuffle} => "is nondeterministic",
    {:Enum, :take_random} => "is nondeterministic"
  }
  @library_functions for {alias_name, module} <- @library_modules,
                         {function, arity} <- module.__info__(:functions),
                         not Map.has_key?(@refused_functions, {alias_name, function}),
                         into: MapSet.new(),
                         do: {alias_name, function, arity}
  # Library functions whose function argument returns an accumulator rather
  # than an element of the result; each return is bounded on its own instead
  # of adding to the call's running total.
  @accumulator_functions [
    {:Enum, :reduce},
    {:Enum, :reduce_while},
    {:Enum, :chunk_while},
    {:List, :foldl},
    {:List, :foldr}
  ]
  @fn_frame {__MODULE__, :fn_frame}
  @fn_failure {__MODULE__, :fn_failure}

  defstruct vars: %{},
            protected_vars: %{},
            callbacks: %{},
            runtime: nil,
            output: "",
            max_steps: @default_max_steps,
            max_output_chars: @default_max_output_chars,
            max_source_bytes: @default_max_source_bytes,
            max_value_bytes: @default_max_value_bytes,
            max_effects: @default_max_effects,
            effect_journal: [],
            effect_results: [],
            effect_requests: [],
            steps: 0,
            in_function: false

  @type t :: %__MODULE__{}

  @doc false
  def controller_language_capabilities do
    %{
      binary_operators: @binary_operators,
      unary_operators: @unary_operators,
      library_modules: @library_modules |> Map.keys() |> Enum.sort(),
      library_functions: @library_functions,
      refused_functions: @refused_functions
    }
  end

  @doc false
  def controller_language_guide do
    """
    The controller executes a small Elixir-shaped language, not general Elixir.
    Supported values and data are strings, numbers, booleans, nil, existing atom literals, lists, maps, tuples, and integer ranges; unfamiliar atom literals are represented as strings rather than creating VM atoms. Supported control is assignment to a variable or a pattern (`{a, b} = pair`, `[first | rest] = lines`), `if condition, do: value, else: value`, and bounded `for pattern <- list_range_or_map, filter, do: expression` comprehensions, which take `into:` and `uniq:` but not `reduce:`. `[item | list]` builds a list. Pipelines with `|>` are supported. Supported operators are #{format_operators(@binary_operators ++ @unary_operators)}. Use `Access.get(container, key)` or `container[key]` for map/list/string access.
    Every function of `Enum`, `Keyword`, `List`, `Map` and `String` is available except #{format_refused()}; a sorter is `:asc`, `:desc` or a function, never a module. Other modules cannot be called or used as values. Without a module, #{format_kernel()} are available.
    Anonymous functions (`fn x -> ... end`, with several clauses, guards, and tuple, list or map patterns) and captures (`&String.downcase/1`, `&(&1 + 1)`) can be passed to those functions. Inside a function, `print` works but registered tools, the task built-ins and `submit` do not; call those from a `for` comprehension instead.
    Important traps: `case`, `hd`, and calling a function stored in a variable are not supported. Use `if` or a multi-clause `fn` instead of `case`, `List.first` instead of `hd`, and string concatenation with `<>` instead of interpolation or binary `<<>>` syntax. String literals themselves are supported.
    Registered tools and the built-ins named in the task prompt are the only effectful calls. A failed cell rolls back its assignments while retaining already-completed effects for deterministic repair.
    """
    |> String.trim()
  end

  @doc "Creates an interpreter with persistent variables and callback runtime."
  def new(vars, callbacks, runtime, opts \\ []) do
    vars = Map.new(vars)
    protected_vars = opts |> Keyword.get(:protected_vars, %{}) |> Map.new()
    vars = restore_protected_vars(vars, protected_vars)
    max_value_bytes = positive_option(opts, :max_value_bytes, @default_max_value_bytes)
    validate_initial_vars!(vars, max_value_bytes)

    %__MODULE__{
      vars: vars,
      protected_vars: protected_vars,
      callbacks: Map.new(callbacks),
      runtime: runtime,
      max_steps: positive_option(opts, :max_steps, @default_max_steps),
      max_output_chars: non_negative_option(opts, :max_output_chars, @default_max_output_chars),
      max_source_bytes: positive_option(opts, :max_source_bytes, @default_max_source_bytes),
      max_value_bytes: max_value_bytes,
      max_effects: positive_option(opts, :max_effects, @default_max_effects)
    }
  end

  @doc "Executes one program, preserving assignments, output, and callback runtime."
  def execute(%__MODULE__{} = interpreter, source) when is_binary(source) do
    execute_with_results(%{interpreter | output: ""}, source, interpreter.effect_journal)
  end

  def execute(%__MODULE__{} = interpreter, _source),
    do: {:error, :source_must_be_a_string, interpreter}

  @doc false
  def commit(%__MODULE__{} = interpreter), do: %{interpreter | effect_journal: []}

  @doc false
  def put_protected(%__MODULE__{} = interpreter, name, value) do
    protected_vars = Map.put(interpreter.protected_vars, to_string(name), value)
    vars = restore_protected_vars(interpreter.vars, protected_vars)

    case validate_value(vars, interpreter.max_value_bytes) do
      :ok -> {:ok, %{interpreter | vars: vars, protected_vars: protected_vars}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def resume(%Continuation{} = continuation, result)
      when elem(result, 0) in [:ok, :error] do
    results = continuation.results ++ [{continuation.request, result}]

    case validate_value(results, continuation.interpreter.max_value_bytes) do
      :ok ->
        execute_with_results(continuation.interpreter, continuation.source, results)

      {:error, reason} ->
        replay_error = {:effect_result_budget_exceeded, reason}

        interpreter = %{
          continuation.interpreter
          | effect_journal:
              continuation.results ++ [{continuation.request, {:error, replay_error}}]
        }

        {:error, replay_error, interpreter}
    end
  end

  defp execute_with_results(interpreter, source, effect_results) do
    original = clean_transient(interpreter)

    interpreter = %{
      original
      | steps: 0,
        effect_results: effect_results,
        effect_requests: []
    }

    with :ok <- check_source_budget(source, interpreter.max_source_bytes),
         {:ok, source} <- unwrap_fence(source),
         {:ok, source} <- normalize_repl_helpers(source),
         {:ok, ast} <- parse(source),
         :ok <- check_ast_budget(ast, interpreter.max_steps) do
      case safe_eval(ast, interpreter) do
        {:ok, value, next} ->
          {:ok, value, finish_transaction(next)}

        {:final, value, next} ->
          {:final, value, preserve_transaction(next, effect_results)}

        {:error, reason, _next} ->
          {:error, reason, rollback_transaction(original, effect_results)}

        {:effect, request, _partial} ->
          if length(effect_results) >= interpreter.max_effects do
            {:error, {:effect_limit_exceeded, interpreter.max_effects},
             rollback_transaction(original, effect_results)}
          else
            {:effect, request,
             %Continuation{
               interpreter: original,
               source: source,
               results: effect_results,
               request: request
             }}
          end
      end
    else
      {:error, reason} -> {:error, reason, original}
    end
  end

  # A defect in the interpreter must reach the model as a failed cell, not
  # end the whole RLM call.
  defp safe_eval(ast, interpreter) do
    eval(ast, interpreter)
  rescue
    error -> {:error, {:interpreter_error, Exception.message(error)}, interpreter}
  end

  defp check_source_budget(source, max_bytes) do
    if byte_size(source) <= max_bytes,
      do: :ok,
      else: {:error, {:source_too_large, byte_size(source), max_bytes}}
  end

  defp parse(source) do
    case Code.string_to_quoted(source,
           columns: true,
           static_atoms_encoder: &encode_existing_atom/2
         ) do
      {:ok, ast} -> {:ok, ast}
      {:error, error} -> {:error, {:parse_error, error}}
    end
  end

  defp encode_existing_atom(value, _metadata) do
    {:ok, existing_atom_or_string(value)}
  end

  defp existing_atom_or_string(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp unwrap_fence(source) do
    trimmed = String.trim(source)

    case Regex.run(~r/\A```([^\n\r]*)\r?\n(.*?)\r?\n```\z/s, trimmed) do
      [_, language, body] ->
        case String.downcase(String.trim(language)) do
          language when language in ["", "elixir", "ex", "exs"] -> {:ok, body}
          language -> {:error, {:unsupported_markdown_language, language}}
        end

      nil ->
        if String.starts_with?(trimmed, "```") do
          {:error, :invalid_markdown_fence}
        else
          {:ok, source}
        end
    end
  end

  # The standalone Python REPL documents this helper in uppercase. Elixir
  # reserves uppercase identifiers for aliases, so normalize only this fixed
  # runtime primitive before parsing generated source.
  defp normalize_repl_helpers(source) do
    {:ok, Regex.replace(~r/(?<![[:alnum:]_])SHOW_VARS\s*\(/, source, "show_vars(")}
  end

  defp check_ast_budget(ast, limit) do
    {_ast, count} = Macro.prewalk(ast, 0, fn node, count -> {node, count + 1} end)
    if count <= limit, do: :ok, else: {:error, :ast_step_limit_exceeded}
  end

  defp eval(ast, state) do
    with {:ok, next} <- tick(state) do
      ast
      |> eval_node(next)
      |> validate_result(state)
    end
  end

  defp validate_result({:ok, value, next}, original) do
    case validate_value(value, next.max_value_bytes) do
      :ok -> {:ok, value, next}
      {:error, reason} -> {:error, reason, original}
    end
  end

  defp validate_result({:final, value, next}, original) do
    case validate_value(value, next.max_value_bytes) do
      :ok -> {:final, value, next}
      {:error, reason} -> {:error, reason, original}
    end
  end

  defp validate_result(other, _original), do: other

  defp clean_transient(interpreter),
    do: %{interpreter | effect_results: [], effect_requests: [], steps: 0}

  defp finish_transaction(interpreter) do
    interpreter = restore_protected_state(interpreter)
    %{clean_transient(interpreter) | effect_journal: []}
  end

  defp preserve_transaction(interpreter, effect_results) do
    interpreter = restore_protected_state(interpreter)
    %{clean_transient(interpreter) | effect_journal: effect_results}
  end

  # A failed cell must not publish ordinary bindings from its partial evaluation.
  # Completed effects remain journaled so an explicit repair does not replay them.
  # `original` may already include values loaded through an effect continuation.
  defp rollback_transaction(interpreter, effect_results) do
    interpreter = restore_protected_state(interpreter)
    %{clean_transient(interpreter) | effect_journal: effect_results}
  end

  defp restore_protected_state(interpreter) do
    %{interpreter | vars: restore_protected_vars(interpreter.vars, interpreter.protected_vars)}
  end

  defp restore_protected_vars(vars, protected_vars) do
    Enum.reduce(protected_vars, vars, fn {name, value}, vars ->
      string_name = to_string(name)
      canonical_name = existing_atom_or_string(string_name)

      vars
      |> Map.delete(string_name)
      |> Map.delete(canonical_name)
      |> Map.put(canonical_name, value)
    end)
  end

  defp validate_value(value, max_bytes) do
    bytes = :erlang.external_size(value)
    if bytes <= max_bytes, do: :ok, else: {:error, {:value_budget_exceeded, bytes, max_bytes}}
  end

  defp validate_initial_vars!(vars, max_bytes) do
    case validate_value(vars, max_bytes) do
      :ok ->
        :ok

      {:error, {:value_budget_exceeded, bytes, ^max_bytes}} ->
        raise ArgumentError,
              "initial RLM variables require #{bytes} bytes, exceeding max_value_bytes #{max_bytes}"
    end
  end

  defp tick(%{steps: steps, max_steps: max} = state) when steps < max,
    do: {:ok, %{state | steps: steps + 1}}

  defp tick(state), do: {:error, :step_limit_exceeded, state}

  defp eval_node(value, state)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value, state}

  defp eval_node(atom, state) when is_atom(atom), do: {:ok, atom, state}

  defp eval_node({:__block__, _, expressions}, state), do: eval_sequence(expressions, state, nil)

  defp eval_node({:=, _, [{name, _, context}, expression]}, state)
       when (is_atom(name) or is_binary(name)) and (is_atom(context) or is_nil(context)) do
    with {:ok, value, state} <- eval(expression, state) do
      {:ok, value, %{state | vars: Map.put(state.vars, name, value)}}
    end
  end

  # `{a, b} = pair`, `[first | rest] = lines`, `%{"id" => id} = row`: the
  # patterns a function clause takes.
  defp eval_node({:=, _, [pattern, expression]}, state) do
    with {:ok, value, state} <- eval(expression, state) do
      case bind(pattern, value, state.vars) do
        {:ok, vars} -> {:ok, value, %{state | vars: vars}}
        :error -> {:error, {:no_match, render(pattern)}, state}
      end
    end
  end

  defp eval_node({name, _, context}, state)
       when (is_atom(name) or is_binary(name)) and (is_atom(context) or is_nil(context)) do
    case fetch_var(state.vars, name) do
      {:ok, value} -> {:ok, value, state}
      :error -> {:error, {:unknown_variable, name}, state}
    end
  end

  defp eval_node({:{}, _, items}, state), do: eval_collection(items, state, &List.to_tuple/1)

  defp eval_node({left, right}, state),
    do: eval_collection([left, right], state, &List.to_tuple/1)

  defp eval_node(list, state) when is_list(list) do
    case List.last(list) do
      {:|, _, [head, tail]} -> eval_cons(Enum.drop(list, -1) ++ [head], tail, state)
      _other -> eval_collection(list, state, & &1)
    end
  end

  defp eval_node({:%{}, _, pairs}, state) do
    eval_pairs(pairs, state, [])
  end

  defp eval_node({:fn, _, clauses}, state), do: build_fn(clauses, state)

  defp eval_node({:&, _, [capture]}, state), do: build_capture(capture, state)

  defp eval_node({:if, _, [condition, clauses]}, state) when is_list(clauses) do
    with {:ok, condition, state} <- eval(condition, state) do
      branch =
        if truthy?(condition), do: Keyword.get(clauses, :do), else: Keyword.get(clauses, :else)

      eval(branch, state)
    end
  end

  defp eval_node({:for, _, args}, state), do: eval_for(args, state)

  defp eval_node({:|>, _, [left, {callee, metadata, args}]}, state) when is_list(args) do
    eval({callee, metadata, [left | args]}, state)
  end

  defp eval_node({:.., _, [first, last]}, state) do
    with {:ok, first, state} <- eval(first, state),
         {:ok, last, state} <- eval(last, state),
         true <- is_integer(first) and is_integer(last) do
      {:ok, Range.new(first, last), state}
    else
      false -> {:error, :range_requires_integers, state}
      other -> other
    end
  end

  defp eval_node({operator, _, [left, right]}, state)
       when operator in @binary_operators do
    eval_binary(operator, left, right, state)
  end

  defp eval_node({operator, _, [value]}, state) when operator in @unary_operators do
    with {:ok, value, state} <- eval(value, state), do: apply_unary(operator, value, state)
  end

  defp eval_node({{:., _, [Access, :get]}, _, [container, key]}, state) do
    with {:ok, container, state} <- eval(container, state),
         {:ok, key, state} <- eval(key, state) do
      {:ok, access(container, key), state}
    end
  end

  defp eval_node({{:., _, [{:__aliases__, _, [module]}, function]}, _, [container, key]}, state)
       when module in [:Access, "Access"] and function in [:get, "get"] do
    with {:ok, container, state} <- eval(container, state),
         {:ok, key, state} <- eval(key, state) do
      {:ok, access(container, key), state}
    end
  end

  defp eval_node({{:., _, [{:__aliases__, _, [module]}, function]}, _, args}, state)
       when (is_atom(function) or is_binary(function)) and is_list(args) and
              (is_map_key(@library_modules, module) or is_binary(module)) do
    eval_allowlisted(module, function, args, state)
  end

  defp eval_node({{:., _, [container, key]}, metadata, []}, state)
       when is_atom(key) or is_binary(key) do
    if Keyword.get(metadata, :no_parens, false) and not match?({:__aliases__, _, _}, container) do
      with {:ok, container, state} <- eval(container, state) do
        case container do
          %{^key => value} -> {:ok, value, state}
          _ -> {:error, {:key_not_found, key}, state}
        end
      end
    else
      eval_module_call(container, key, [], state)
    end
  end

  defp eval_node({{:., _, [module, function]}, _, args}, state)
       when (is_atom(function) or is_binary(function)) and is_list(args),
       do: eval_module_call(module, function, args, state)

  defp eval_node({:print, _, [expression]}, state) do
    with {:ok, value, state} <- eval(expression, state) do
      text = if is_binary(value), do: value, else: inspect(value)
      remaining = max(state.max_output_chars - String.length(state.output), 0)
      addition = String.slice(text, 0, remaining)
      {:ok, value, %{state | output: state.output <> addition}}
    end
  end

  defp eval_node({:submit, _, args}, %{in_function: true} = state) when is_list(args),
    do: {:error, :submit_inside_fn, state}

  defp eval_node({:submit, _, args}, state) when is_list(args) do
    with {:ok, values, state} <- eval_arguments(args, state),
         {:ok, output} <- submission(values),
         :ok <- check_constructed(output, state) do
      {:final, output, state}
    else
      {:error, reason} -> {:error, reason, state}
      other -> other
    end
  end

  # Source-compatible namespace inspection without exposing callback or runtime
  # internals to generated code.
  defp eval_node({name, _, []}, state) when name in [:show_vars, "show_vars"] do
    variables =
      state.vars
      |> Enum.map(fn {key, value} -> {to_string(key), type_name(value)} end)
      |> Enum.sort()
      |> Map.new()

    {:ok, "Available variables: #{inspect(variables)}", state}
  end

  # `f.(x)`. An interpreter function runs only where a library function
  # applies it, and a variable that holds anything else is not a function at
  # all. Either way the model reads why.
  defp eval_node({{:., _, [callee]}, _, args}, state) when is_list(args) do
    with {:ok, value, state} <- eval(callee, state) do
      case value do
        %Fn{} ->
          {:error,
           {:unsupported_expression,
            "calling a function held in a variable (#{render(callee)}.(...)); " <>
              "pass it to an Enum function, or write its body inline"}, state}

        _other ->
          {:error, {:not_a_function, render(callee), value}, state}
      end
    end
  end

  # A module named as a value (`File`, `m = File.Stream`) is never data: a
  # module is how a forged struct or a sorter reaches code outside the
  # language.
  defp eval_node({:__aliases__, _, parts}, state) when is_list(parts),
    do: {:error, {:module_value_not_allowed, Enum.map_join(parts, ".", &to_string/1)}, state}

  defp eval_node({name, _, args}, state)
       when (is_atom(name) or is_binary(name)) and is_list(args) do
    if {normalize_known_name(name), length(args)} in @kernel_functions and
         not Map.has_key?(state.callbacks, name) and
         not Map.has_key?(state.callbacks, to_string(name)) do
      eval_kernel(normalize_known_name(name), args, state)
    else
      invoke_callback(name, args, state)
    end
  end

  defp eval_node(ast, state), do: {:error, {:unsupported_expression, render(ast)}, state}

  # The parser keeps a name whose atom does not exist as a string, which
  # `Macro.to_string/1` cannot print. Each such name is printed through a
  # placeholder variable and put back in order; no atom is created.
  defp render(ast) do
    {ast, names} =
      Macro.prewalk(ast, [], fn
        {name, meta, context}, names when is_binary(name) and is_atom(context) ->
          {{:imp_rendered_name, meta, nil}, [name | names]}

        other, names ->
          {other, names}
      end)

    names
    |> Enum.reverse()
    |> Enum.reduce(Macro.to_string(ast), fn name, text ->
      String.replace(text, "imp_rendered_name", name, global: false)
    end)
  rescue
    _error -> "an expression"
  end

  # `to_string/1` and `is_nil/1` are macros in Kernel, not functions.
  defp kernel_apply(:to_string, [value]), do: String.Chars.to_string(value)
  defp kernel_apply(:is_nil, [value]), do: value == nil
  defp kernel_apply(name, values), do: apply(Kernel, name, values)

  defp eval_kernel(name, args, state) do
    with {:ok, values, state} <- eval_arguments(args, state),
         :ok <- check_library_arguments(values, state) do
      {:ok, kernel_apply(name, values), state}
    end
  rescue
    error -> {:error, {:kernel_call_failed, name, Exception.message(error)}, state}
  end

  defp eval_module_call(module, function, args, state) do
    module =
      case module do
        {:__aliases__, _, parts} -> Enum.map_join(parts, ".", &to_string/1)
        module when is_atom(module) or is_binary(module) -> to_string(module)
        module -> render(module)
      end

    {:error,
     {:function_not_allowed, existing_atom_or_string(module), normalize_known_name(function),
      length(args)}, state}
  end

  # `[x | acc]`: the items in front of a list.
  defp eval_cons(items, tail, state) do
    with {:ok, items, state} <- eval_arguments(items, state),
         {:ok, tail, state} <- eval(tail, state) do
      if is_list(tail) do
        with :ok <- check_projected_budget(projected_list_concat_size(items, tail), state) do
          {:ok, items ++ tail, state}
        end
      else
        {:error, {:invalid_operands, :|}, state}
      end
    end
  end

  defp eval_sequence([], state, value), do: {:ok, value, state}

  defp eval_sequence([expression | rest], state, _value) do
    case eval(expression, state) do
      {:ok, value, state} -> eval_sequence(rest, state, value)
      other -> other
    end
  end

  defp eval_collection(items, state, finish) do
    with {:ok, values, state} <- eval_arguments(items, state), do: {:ok, finish.(values), state}
  end

  defp eval_arguments(items, state), do: eval_arguments(items, state, [])
  defp eval_arguments([], state, values), do: {:ok, Enum.reverse(values), state}

  defp eval_arguments([item | rest], state, values) do
    case eval(item, state) do
      {:ok, value, state} -> eval_arguments(rest, state, [value | values])
      other -> other
    end
  end

  defp eval_pairs([], state, pairs), do: {:ok, Map.new(Enum.reverse(pairs)), state}

  # A map with a `__struct__` key is dispatched by every protocol as that
  # struct, so controller code may not write one (see `check_constructed/2`).
  defp eval_pairs([{key, value} | rest], state, pairs) do
    with {:ok, key, state} <- eval(key, state),
         :ok <- refuse_struct_key(key, state),
         {:ok, value, state} <- eval(value, state) do
      eval_pairs(rest, state, [{key, value} | pairs])
    end
  end

  defp eval_pairs(_pairs, state, _result), do: {:error, :invalid_map, state}

  defp refuse_struct_key(:__struct__, state), do: {:error, :struct_key_not_allowed, state}
  defp refuse_struct_key(_key, _state), do: :ok

  defp eval_binary(operator, left_ast, right_ast, state) when operator in [:and, :&&, :or, :||] do
    with {:ok, left, state} <- eval(left_ast, state) do
      case {operator, truthy?(left)} do
        {operator, false} when operator in [:and, :&&] -> {:ok, left, state}
        {operator, true} when operator in [:or, :||] -> {:ok, left, state}
        _ -> eval(right_ast, state)
      end
    end
  end

  defp eval_binary(operator, left, right, state) do
    with {:ok, left, state} <- eval(left, state),
         {:ok, right, state} <- eval(right, state) do
      apply_binary(operator, left, right, state)
    end
  end

  defp apply_binary(:+, a, b, state) when is_number(a) and is_number(b), do: {:ok, a + b, state}
  defp apply_binary(:-, a, b, state) when is_number(a) and is_number(b), do: {:ok, a - b, state}

  defp apply_binary(:*, a, b, state) when is_integer(a) and is_integer(b) do
    with :ok <- check_integer_product_budget(a, b, state) do
      {:ok, a * b, state}
    end
  end

  defp apply_binary(:*, a, b, state) when is_number(a) and is_number(b), do: {:ok, a * b, state}

  defp apply_binary(:/, a, b, state) when is_number(a) and is_number(b) and b != 0,
    do: {:ok, a / b, state}

  defp apply_binary(:div, a, b, state) when is_integer(a) and is_integer(b) and b != 0,
    do: {:ok, div(a, b), state}

  defp apply_binary(:rem, a, b, state) when is_integer(a) and is_integer(b) and b != 0,
    do: {:ok, rem(a, b), state}

  defp apply_binary(:==, a, b, state), do: {:ok, a == b, state}
  defp apply_binary(:!=, a, b, state), do: {:ok, a != b, state}
  defp apply_binary(:===, a, b, state), do: {:ok, a === b, state}
  defp apply_binary(:!==, a, b, state), do: {:ok, a !== b, state}
  defp apply_binary(:<, a, b, state), do: {:ok, a < b, state}
  defp apply_binary(:<=, a, b, state), do: {:ok, a <= b, state}
  defp apply_binary(:>, a, b, state), do: {:ok, a > b, state}
  defp apply_binary(:>=, a, b, state), do: {:ok, a >= b, state}

  defp apply_binary(:<>, a, b, state) when is_binary(a) and is_binary(b) do
    with :ok <- check_projected_budget(byte_size(a) + byte_size(b) + 6, state) do
      {:ok, a <> b, state}
    end
  end

  defp apply_binary(:++, a, b, state) when is_list(a) and is_list(b) do
    with :ok <- check_projected_budget(projected_list_concat_size(a, b), state) do
      {:ok, a ++ b, state}
    end
  end

  defp apply_binary(:--, a, b, state) when is_list(a) and is_list(b), do: {:ok, a -- b, state}

  defp apply_binary(:in, a, b, state) when is_list(b) or is_struct(b, Range),
    do: {:ok, a in b, state}

  defp apply_binary(operator, _a, _b, state), do: {:error, {:invalid_operands, operator}, state}

  defp apply_unary(:+, value, state) when is_number(value), do: {:ok, value, state}
  defp apply_unary(:-, value, state) when is_number(value), do: {:ok, -value, state}

  defp apply_unary(operator, value, state) when operator in [:!, :not],
    do: {:ok, not truthy?(value), state}

  defp apply_unary(operator, _value, state), do: {:error, {:invalid_operand, operator}, state}

  defp eval_for(args, state) do
    {clauses, options} = Enum.split_while(args, &(not keyword_ast?(&1)))
    options = Enum.concat(options)
    body = Keyword.get(options, :do)

    case Keyword.keys(options) -- [:do, :into, :uniq] do
      [] when is_nil(body) ->
        {:error, :for_requires_do_block, state}

      [] ->
        with {:ok, values, state} <- eval_for_clauses(clauses, body, state, []),
             {:ok, uniq, state} <- eval(Keyword.get(options, :uniq, false), state) do
          values = if truthy?(uniq), do: Enum.uniq(values), else: values
          collect_for(Keyword.fetch(options, :into), values, state)
        end

      [option | _rest] ->
        {:error, {:unsupported_for_option, option, "use Enum.reduce instead"}, state}
    end
  end

  # `into:` collects the results as `Enum.into/2` would, under its checks.
  defp collect_for(:error, values, state), do: {:ok, values, state}

  defp collect_for({:ok, into}, values, state) do
    with {:ok, into, state} <- eval(into, state) do
      eval_allowlisted_values(:Enum, :into, [values, into], state)
    end
  end

  defp keyword_ast?(value), do: is_list(value) and Keyword.keyword?(value)

  defp eval_for_clauses([], body, state, results) do
    case eval(body, state) do
      {:ok, value, state} ->
        with :ok <- check_projected_budget(projected_list_append_size(results, value), state) do
          {:ok, results ++ [value], state}
        end

      other ->
        other
    end
  end

  # A generator's pattern is a function clause's (`{key, value} <- map`), and
  # an item that does not match it is skipped, as in Elixir.
  defp eval_for_clauses([{:<-, _, [pattern, enumerable]} | rest], body, state, results) do
    with {:ok, enumerable, state} <- eval(enumerable, state),
         true <- is_list(enumerable) or is_struct(enumerable, Range) or plain_map?(enumerable) do
      Enum.reduce_while(enumerable, {:ok, results, state}, fn item, {:ok, acc, current} ->
        case bind(pattern, item, current.vars) do
          {:ok, vars} ->
            case eval_for_clauses(rest, body, %{current | vars: vars}, acc) do
              {:ok, produced, next} -> {:cont, {:ok, produced, next}}
              other -> {:halt, other}
            end

          :error ->
            {:cont, {:ok, acc, current}}
        end
      end)
      |> restore_for_var(state, pattern_names(pattern))
    else
      false -> {:error, :for_requires_list_range_or_map, state}
      other -> other
    end
  end

  defp eval_for_clauses([filter | rest], body, state, results) do
    case eval(filter, state) do
      {:ok, value, state} when value not in [false, nil] ->
        eval_for_clauses(rest, body, state, results)

      {:ok, _value, state} ->
        {:ok, results, state}

      other ->
        other
    end
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp pattern_names(pattern) do
    {_pattern, names} =
      Macro.prewalk(pattern, [], fn
        {name, _, context} = node, names
        when (is_atom(name) or is_binary(name)) and (is_atom(context) or is_nil(context)) ->
          {node, [name | names]}

        node, names ->
          {node, names}
      end)

    names
  end

  defp restore_for_var({:ok, values, next}, original, names) do
    {:ok, values, restore_for_vars(next, original, names)}
  end

  defp restore_for_var(
         {:error, {:value_budget_exceeded, _bytes, _max_bytes} = reason, next},
         original,
         names
       ) do
    {:error, reason, restore_for_vars(next, original, names)}
  end

  defp restore_for_var(other, _original, _names), do: other

  defp restore_for_vars(next, original, names),
    do: Enum.reduce(names, next, &restore_for_var_binding(&2, original, &1))

  defp restore_for_var_binding(next, original, name) do
    vars =
      case fetch_var(original.vars, name) do
        {:ok, value} -> Map.put(next.vars, name, value)
        :error -> Map.delete(next.vars, name)
      end

    %{next | vars: vars}
  end

  defp eval_allowlisted(module, function, args, state) do
    module = normalize_known_name(module)
    function = normalize_known_name(function)

    if {module, function, length(args)} in @library_functions do
      with {:ok, values, state} <- eval_arguments(args, state),
           do: eval_allowlisted_values(module, function, values, state)
    else
      {:error, {:function_not_allowed, module, function, length(args)}, state}
    end
  end

  defp eval_allowlisted_values(module, function, values, state) do
    with :ok <- check_library_arguments(values, state),
         :ok <- check_module_arguments(module, function, values, state),
         :ok <- check_transformation_budget(module, function, values, state),
         {:ok, value, state} <- apply_library(module, function, values, state),
         :ok <- check_constructed(value, state) do
      {:ok, value, state}
    end
  end

  # Protocols dispatch on a map's `__struct__` key, so a map that merely
  # carries one is treated as that struct: a map shaped like a File.Stream
  # sends `Enum.join` into `Enumerable.File.Stream` and reads the named file,
  # and the same holds for Collectable, String.Chars, Inspect and any other
  # protocol with an implementation loaded in the VM. Controller code
  # therefore never holds a struct it did not receive from the host: a map
  # literal may not name the key (`eval_pairs/3`), and the result of every
  # library call is checked here, since library functions build maps from
  # data. Genuine ranges and MapSets, and the interpreter's own functions,
  # are the only structs a library call may take or return; no other struct,
  # and no Elixir module named as a value (a forged struct's module, or a
  # sorter whose `compare/2` would run), is passed to one.
  @data_structs [Range, MapSet]

  # Two kinds of library argument name a module whose functions the library
  # then calls: a sorter that is a module (or `{:asc, module}`) has its
  # `compare/2` called, and `Map.from_struct/1` given a module calls its
  # `__struct__/0`. Elixir modules are refused as values anywhere; an Erlang
  # module is an ordinary atom, so here only `:asc`, `:desc` and functions
  # sort, and `Map.from_struct/1` takes a struct.
  @sorting_functions [
    {:Enum, :sort},
    {:Enum, :sort_by},
    {:Enum, :min},
    {:Enum, :max},
    {:Enum, :min_by},
    {:Enum, :max_by},
    {:Enum, :min_max_by},
    {:List, :keysort}
  ]

  defp check_module_arguments(:Map, :from_struct, [module], state) when is_atom(module),
    do: {:error, {:module_value_not_allowed, module}, state}

  defp check_module_arguments(module, function, [_enumerable | rest], state)
       when {module, function} in @sorting_functions do
    case Enum.find(rest, &module_sorter?/1) do
      nil -> :ok
      sorter -> {:error, {:sorter_not_allowed, sorter}, state}
    end
  end

  defp check_module_arguments(_module, _function, _values, _state), do: :ok

  defp module_sorter?(direction) when direction in [:asc, :desc], do: false
  defp module_sorter?(value) when is_atom(value), do: true
  defp module_sorter?({_direction, module}) when is_atom(module), do: true
  defp module_sorter?(_value), do: false

  defp check_library_arguments(values, state) do
    case Enum.find_value(values, &library_argument_error(&1, state.max_value_bytes)) do
      nil -> :ok
      reason -> {:error, reason, state}
    end
  end

  defp check_constructed(value, state) do
    case forged_struct(value) do
      nil ->
        :ok

      function when is_function(function) ->
        {:error,
         {:function_value_not_allowed,
          "a library call returned a function it was given; a function is only an argument to a library call"},
         state}

      _forged ->
        {:error, :struct_key_not_allowed, state}
    end
  end

  # An interpreter function is AST the interpreter runs; what it touches is
  # checked when it runs.
  defp library_argument_error(%Fn{}, _max_bytes), do: nil

  # Library functions materialize a range before the result's size can be
  # checked, and each element takes at least a byte of the value budget.
  defp library_argument_error(%Range{} = range, max_bytes) do
    cond do
      not genuine_data_struct?(range) -> {:module_value_not_allowed, Range}
      Range.size(range) > max_bytes -> {:value_budget_exceeded, Range.size(range), max_bytes}
      true -> nil
    end
  end

  defp library_argument_error(%{__struct__: module} = value, max_bytes) do
    if genuine_data_struct?(value),
      do: value |> Map.from_struct() |> library_argument_error(max_bytes),
      else: {:module_value_not_allowed, module}
  end

  defp library_argument_error(value, max_bytes) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      library_argument_error(key, max_bytes) || library_argument_error(item, max_bytes)
    end)
  end

  defp library_argument_error([head | tail], max_bytes),
    do: library_argument_error(head, max_bytes) || library_argument_error(tail, max_bytes)

  defp library_argument_error(value, max_bytes) when is_tuple(value),
    do: value |> Tuple.to_list() |> library_argument_error(max_bytes)

  defp library_argument_error(value, _max_bytes)
       when is_atom(value) and value not in @data_structs do
    if String.starts_with?(Atom.to_string(value), "Elixir."),
      do: {:module_value_not_allowed, value},
      else: nil
  end

  defp library_argument_error(_value, _max_bytes), do: nil

  defp forged_struct(%{__struct__: _module} = value) do
    if genuine_data_struct?(value),
      do: value |> Map.from_struct() |> forged_struct(),
      else: value
  end

  defp forged_struct(value) when is_map(value),
    do: Enum.find_value(value, fn {key, item} -> forged_struct(key) || forged_struct(item) end)

  defp forged_struct([head | tail]), do: forged_struct(head) || forged_struct(tail)
  defp forged_struct(value) when is_tuple(value), do: value |> Tuple.to_list() |> forged_struct()
  # A library call is given an interpreter function as a native closure
  # (`native_function/2`), and some hand an argument back (`Map.get(m, k,
  # f)`, a `reduce` over nothing): such a closure is not a value code keeps.
  defp forged_struct(value) when is_function(value), do: value
  defp forged_struct(_value), do: nil

  defp genuine_data_struct?(%Range{first: first, last: last, step: step} = range),
    do: is_integer(first) and is_integer(last) and is_integer(step) and map_size(range) == 4

  defp genuine_data_struct?(%MapSet{map: map} = set), do: is_map(map) and map_size(set) == 2

  defp genuine_data_struct?(%Fn{arity: arity, clauses: clauses} = function),
    do: arity in 0..3 and is_list(clauses) and map_size(function) == 3

  defp genuine_data_struct?(_value), do: false

  # Interpreter functions run inside a native library call, which cannot
  # thread interpreter state. The call's step count, output and the running
  # size of its function results live in a frame in the process dictionary
  # for the duration of the call, and are folded back into the state after
  # it; the previous frame is restored so calls may nest.
  defp apply_library(module, function, values, state) do
    outer = Process.get(@fn_frame)

    Process.put(@fn_frame, %{
      steps: state.steps,
      output: state.output,
      bytes: 0,
      counted: {module, function} not in @accumulator_functions
    })

    try do
      value =
        apply(Map.fetch!(@library_modules, module), function, native_arguments(values, state))

      frame = Process.get(@fn_frame)
      {:ok, value, %{state | steps: frame.steps, output: frame.output}}
    rescue
      error -> {:error, {:transformation_error, Exception.message(error)}, state}
    catch
      :throw, {@fn_failure, reason} -> {:error, reason, state}
    after
      if outer, do: Process.put(@fn_frame, outer), else: Process.delete(@fn_frame)
    end
  end

  defp native_arguments(values, state), do: Enum.map(values, &native_function(&1, state))

  defp native_function(%Fn{arity: 0} = function, state),
    do: fn -> call_fn(function, [], state) end

  defp native_function(%Fn{arity: 1} = function, state),
    do: fn a -> call_fn(function, [a], state) end

  defp native_function(%Fn{arity: 2} = function, state),
    do: fn a, b -> call_fn(function, [a, b], state) end

  defp native_function(%Fn{arity: 3} = function, state),
    do: fn a, b, c -> call_fn(function, [a, b, c], state) end

  defp native_function(value, _state), do: value

  defp call_fn(%Fn{clauses: clauses}, args, state) do
    frame = Process.get(@fn_frame)
    state = %{state | steps: frame.steps, output: frame.output, in_function: true}

    result =
      with {:ok, body, state} <- select_clause(clauses, args, state) do
        eval(body, state)
      end

    case result do
      {:ok, value, next} ->
        bytes = if frame.counted, do: frame.bytes + :erlang.external_size(value), else: 0

        if bytes > state.max_value_bytes,
          do: throw({@fn_failure, {:value_budget_exceeded, bytes, state.max_value_bytes}})

        Process.put(@fn_frame, %{frame | steps: next.steps, output: next.output, bytes: bytes})
        value

      {:error, reason, _state} ->
        throw({@fn_failure, reason})
    end
  end

  defp select_clause([], args, state), do: {:error, {:fn_clause_not_matched, args}, state}

  defp select_clause([{params, guard, body} | rest], args, state) do
    with {:ok, vars} <- bind_all(params, args, state.vars),
         {:ok, true, state} <- eval_guard(guard, %{state | vars: vars}) do
      {:ok, body, state}
    else
      :error -> select_clause(rest, args, state)
      {:ok, false, _state} -> select_clause(rest, args, state)
      {:error, reason, _state} -> {:error, reason, state}
    end
  end

  defp eval_guard(nil, state), do: {:ok, true, state}

  defp eval_guard(guard, state) do
    with {:ok, value, state} <- eval(guard, state), do: {:ok, truthy?(value), state}
  end

  defp bind_all([], [], vars), do: {:ok, vars}

  defp bind_all([pattern | patterns], [value | values], vars) do
    with {:ok, vars} <- bind(pattern, value, vars), do: bind_all(patterns, values, vars)
  end

  defp bind_all(_patterns, _values, _vars), do: :error

  defp bind({:^, _, [{name, _, context}]}, value, vars)
       when (is_atom(name) or is_binary(name)) and (is_atom(context) or is_nil(context)) do
    case fetch_var(vars, name) do
      {:ok, pinned} when pinned === value -> {:ok, vars}
      _other -> :error
    end
  end

  defp bind({name, _, context}, value, vars)
       when (is_atom(name) or is_binary(name)) and (is_atom(context) or is_nil(context)) do
    if String.starts_with?(to_string(name), "_"),
      do: {:ok, vars},
      else: {:ok, Map.put(vars, name, value)}
  end

  defp bind({:=, _, [left, right]}, value, vars) do
    with {:ok, vars} <- bind(left, value, vars), do: bind(right, value, vars)
  end

  defp bind({:{}, _, patterns}, value, vars) when is_tuple(value),
    do: bind_all(patterns, Tuple.to_list(value), vars)

  defp bind({:%{}, _, pairs}, value, vars) when is_map(value) do
    Enum.reduce_while(pairs, {:ok, vars}, fn {key, pattern}, {:ok, vars} ->
      with {:ok, item} <- Map.fetch(value, key),
           {:ok, vars} <- bind(pattern, item, vars) do
        {:cont, {:ok, vars}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp bind({left, right}, {a, b}, vars), do: bind_all([left, right], [a, b], vars)

  defp bind(patterns, value, vars) when is_list(patterns) and is_list(value) do
    case List.last(patterns) do
      {:|, _, [head, tail]} ->
        count = length(patterns) - 1

        if length(value) > count do
          {items, rest} = Enum.split(value, count)
          bind_all(Enum.drop(patterns, -1) ++ [head, tail], items ++ [hd(rest), tl(rest)], vars)
        else
          :error
        end

      _ ->
        bind_all(patterns, value, vars)
    end
  end

  defp bind(literal, value, vars)
       when is_binary(literal) or is_number(literal) or is_atom(literal) do
    if literal === value, do: {:ok, vars}, else: :error
  end

  defp bind(_pattern, _value, _vars), do: :error

  defp build_fn(clauses, state) do
    clauses =
      Enum.map(clauses, fn
        {:->, _, [[{:when, _, params_and_guard}], body]} ->
          {params, [guard]} = Enum.split(params_and_guard, -1)
          {params, guard, body}

        {:->, _, [params, body]} ->
          {params, nil, body}
      end)

    case clauses |> Enum.map(fn {params, _, _} -> length(params) end) |> Enum.uniq() do
      [arity] when arity <= 3 -> {:ok, %Fn{arity: arity, clauses: clauses}, state}
      _ -> {:error, :fn_arity_not_supported, state}
    end
  end

  defp build_capture({:/, _, [call, arity]}, state)
       when is_integer(arity) and arity in 0..3 do
    params = for index <- 1..arity//1, do: {"&#{index}", [], nil}

    case call do
      {{:., _, [_module, function]} = callee, _, []} when is_atom(function) ->
        {:ok, %Fn{arity: arity, clauses: [{params, nil, {callee, [], params}}]}, state}

      {name, _, context} when is_atom(name) and is_atom(context) ->
        {:ok, %Fn{arity: arity, clauses: [{params, nil, {name, [], params}}]}, state}

      _ ->
        build_capture_expression({:/, [], [call, arity]}, state)
    end
  end

  defp build_capture(expression, state), do: build_capture_expression(expression, state)

  defp build_capture_expression(expression, state) do
    {body, arity} =
      Macro.prewalk(expression, 0, fn
        {:&, _, [index]}, arity when is_integer(index) ->
          {{"&#{index}", [], nil}, max(arity, index)}

        node, arity ->
          {node, arity}
      end)

    if arity in 1..3 do
      params = for index <- 1..arity, do: {"&#{index}", [], nil}
      {:ok, %Fn{arity: arity, clauses: [{params, nil, body}]}, state}
    else
      {:error, :invalid_capture, state}
    end
  end

  defp format_kernel do
    @kernel_functions
    |> Enum.sort()
    |> Enum.map_join(", ", fn {name, arity} -> "`#{name}/#{arity}`" end)
  end

  defp format_refused do
    @refused_functions
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map_join(", ", fn {module, function} -> "`#{module}.#{function}`" end)
  end

  defp format_operators(operators) do
    operators
    |> Enum.map_join(" ", &Atom.to_string/1)
    |> then(&"`#{&1}`")
  end

  defp invoke_callback(name, args, state) do
    effect =
      Map.get(state.callbacks, name) ||
        if(is_atom(name), do: Map.get(state.callbacks, Atom.to_string(name)))

    cond do
      effect && state.in_function ->
        {:error, {:effect_inside_fn, to_string(name)}, state}

      effect ->
        invoke_effect(effect, name, args, state)

      true ->
        {:error, {:function_not_allowed, name}, state}
    end
  end

  defp invoke_effect(effect, name, args, state) do
    with {:ok, values, state} <- eval_arguments(args, state) do
      request = %Effect{kind: effect, name: to_string(name), arguments: values}
      occurrence = Enum.count(state.effect_requests, &(&1 == request))

      case effect_result(state.effect_results, request, occurrence) do
        :error ->
          {:effect, request, state}

        {:ok, {:ok, value}} ->
          {:ok, value, %{state | effect_requests: [request | state.effect_requests]}}

        {:ok, {:error, reason}} ->
          {:error, reason, %{state | effect_requests: [request | state.effect_requests]}}
      end
    end
  end

  defp effect_result(results, request, occurrence) do
    results
    |> Enum.filter(fn {recorded, _result} -> recorded == request end)
    |> Enum.fetch(occurrence)
    |> case do
      {:ok, {_request, result}} -> {:ok, result}
      :error -> :error
    end
  end

  defp submission([map]) when is_map(map), do: {:ok, map}

  defp submission([values]) when is_list(values) do
    if Keyword.keyword?(values),
      do: {:ok, Map.new(values)},
      else: {:error, :submit_requires_a_map}
  end

  defp submission(values) when is_list(values) do
    if Keyword.keyword?(values),
      do: {:ok, Map.new(values)},
      else: {:error, :submit_requires_a_map}
  end

  defp access(container, key) when is_map(container), do: Map.get(container, key)

  defp access(container, key) when is_list(container) and is_integer(key),
    do: Enum.at(container, key)

  defp access(container, key) when is_binary(container) and is_integer(key),
    do: String.at(container, key)

  defp access(_container, _key), do: nil

  defp check_transformation_budget(:String, :replace, [string, pattern, replacement], state)
       when is_binary(string) and is_binary(pattern) and is_binary(replacement) do
    check_string_replace_budget(string, pattern, replacement, state)
  end

  defp check_transformation_budget(:String, :split, values, state)
       when length(values) in [1, 2] do
    check_string_split_budget(values, state)
  end

  defp check_transformation_budget(:Enum, :concat, [enumerables], state)
       when is_list(enumerables) do
    case projected_concat_size(enumerables, state.max_value_bytes) do
      {:ok, bytes} -> check_projected_budget(bytes, state)
      {:error, bytes} -> value_budget_error(bytes, state)
      :unknown -> :ok
    end
  end

  defp check_transformation_budget(:String, :duplicate, [string, count], state)
       when is_binary(string) and is_integer(count) and count >= 0,
       do: check_projected_budget(byte_size(string) * count + 6, state)

  defp check_transformation_budget(:List, :duplicate, [value, count], state)
       when is_integer(count) and count >= 0,
       do: check_projected_budget(:erlang.external_size(value) * count + 6, state)

  defp check_transformation_budget(:String, function, [string, count | padding], state)
       when function in [:pad_leading, :pad_trailing] and is_binary(string) and
              is_integer(count) and count >= 0 do
    padding_bytes =
      case padding do
        [pad] when is_binary(pad) -> max(byte_size(pad), 1)
        _ -> 1
      end

    check_projected_budget(byte_size(string) + count * padding_bytes + 6, state)
  end

  defp check_transformation_budget(_module, _function, _values, _state), do: :ok

  defp check_string_replace_budget(string, "", replacement, state) do
    replacements = String.length(string) + 1
    check_projected_budget(byte_size(string) + replacements * byte_size(replacement) + 6, state)
  end

  defp check_string_replace_budget(string, pattern, replacement, state) do
    projected = byte_size(string) + 6
    adjustment = byte_size(replacement) - byte_size(pattern)

    count_replacement_size(string, pattern, adjustment, projected, state)
  end

  defp count_replacement_size(string, pattern, adjustment, projected, state) do
    case :binary.match(string, pattern) do
      :nomatch ->
        check_projected_budget(projected, state)

      {offset, length} ->
        projected = projected + adjustment

        with :ok <- check_projected_budget(projected, state) do
          remaining = byte_size(string) - offset - length
          rest = binary_part(string, offset + length, remaining)
          count_replacement_size(rest, pattern, adjustment, projected, state)
        end
    end
  end

  defp check_string_split_budget([string, pattern], state)
       when is_binary(string) and is_binary(pattern) do
    check_string_splitter_budget(String.splitter(string, pattern), state)
  end

  defp check_string_split_budget([string, patterns], state)
       when is_binary(string) and is_list(patterns) do
    if Enum.all?(patterns, &is_binary/1) do
      check_string_splitter_budget(String.splitter(string, patterns), state)
    else
      :ok
    end
  end

  defp check_string_split_budget(_values, _state), do: :ok

  defp check_string_splitter_budget(splitter, state) do
    Enum.reduce_while(splitter, {:ok, 2, :empty}, fn part, {:ok, bytes, encoding} ->
      {projected, next_encoding} = projected_list_element_size(bytes, encoding, part)

      case check_projected_budget(projected, state) do
        :ok -> {:cont, {:ok, projected, next_encoding}}
        {:error, reason, next} -> {:halt, {:error, reason, next}}
      end
    end)
    |> case do
      {:ok, _bytes, _encoding} -> :ok
      {:error, reason, next} -> {:error, reason, next}
    end
  end

  defp projected_concat_size(enumerables, max_bytes) do
    Enum.reduce_while(enumerables, {:ok, 2, :empty}, fn enumerable, {:ok, bytes, encoding} ->
      case project_known_enumerable(enumerable, bytes, encoding, max_bytes) do
        {:ok, next_bytes, next_encoding} ->
          {:cont, {:ok, next_bytes, next_encoding}}

        {:error, projected} ->
          {:halt, {:error, projected}}

        :unknown ->
          {:halt, :unknown}
      end
    end)
    |> case do
      {:ok, bytes, _encoding} -> {:ok, bytes}
      other -> other
    end
  end

  defp project_known_enumerable(enumerable, bytes, encoding, max_bytes)
       when is_list(enumerable) or is_struct(enumerable, Range) do
    Enum.reduce_while(enumerable, {:ok, bytes, encoding}, fn value,
                                                             {:ok, size, current_encoding} ->
      {projected, next_encoding} =
        projected_list_element_size(size, current_encoding, value)

      if projected > max_bytes,
        do: {:halt, {:error, projected}},
        else: {:cont, {:ok, projected, next_encoding}}
    end)
  end

  defp project_known_enumerable(_enumerable, _bytes, _encoding, _max_bytes), do: :unknown

  defp projected_list_concat_size([], right), do: :erlang.external_size(right)
  defp projected_list_concat_size(left, []), do: :erlang.external_size(left)

  defp projected_list_concat_size(left, right) do
    if byte_list_encoding?(left) and byte_list_encoding?(right) and
         length(left) + length(right) <= 65_535 do
      length(left) + length(right) + 4
    else
      7 + list_element_bytes(left) + list_element_bytes(right)
    end
  end

  defp projected_list_append_size(values, value) do
    {bytes, encoding} = list_encoding(values)
    {projected, _encoding} = projected_list_element_size(bytes, encoding, value)
    projected
  end

  defp projected_list_element_size(_bytes, :empty, value) when value in 0..255,
    do: {5, {:byte_list, 1}}

  defp projected_list_element_size(_bytes, :empty, value),
    do: {6 + :erlang.external_size(value), :general_list}

  defp projected_list_element_size(bytes, {:byte_list, count}, value)
       when value in 0..255 and count < 65_535,
       do: {bytes + 1, {:byte_list, count + 1}}

  defp projected_list_element_size(_bytes, {:byte_list, count}, value) do
    projected = 7 + count * 2 + :erlang.external_size(value) - 1
    {projected, :general_list}
  end

  defp projected_list_element_size(bytes, :general_list, value),
    do: {bytes + :erlang.external_size(value) - 1, :general_list}

  defp list_encoding([]), do: {2, :empty}

  defp list_encoding(values) do
    bytes = :erlang.external_size(values)

    if byte_list_encoding?(values),
      do: {bytes, {:byte_list, length(values)}},
      else: {bytes, :general_list}
  end

  defp byte_list_encoding?(values) do
    length = length(values)
    length <= 65_535 and :erlang.external_size(values) == length + 4
  end

  defp list_element_bytes(values) do
    if byte_list_encoding?(values),
      do: length(values) * 2,
      else: :erlang.external_size(values) - 7
  end

  defp check_integer_product_budget(0, _right, _state), do: :ok
  defp check_integer_product_budget(_left, 0, _state), do: :ok

  defp check_integer_product_budget(left, right, state) do
    minimum_bits = integer_bit_length(left) + integer_bit_length(right) - 1
    check_projected_budget(integer_external_size_lower_bound(minimum_bits), state)
  end

  defp integer_bit_length(integer) do
    <<first, _rest::binary>> = encoded = :binary.encode_unsigned(abs(integer))
    (byte_size(encoded) - 1) * 8 + first_byte_bit_length(first)
  end

  defp first_byte_bit_length(byte) when byte >= 128, do: 8
  defp first_byte_bit_length(byte) when byte >= 64, do: 7
  defp first_byte_bit_length(byte) when byte >= 32, do: 6
  defp first_byte_bit_length(byte) when byte >= 16, do: 5
  defp first_byte_bit_length(byte) when byte >= 8, do: 4
  defp first_byte_bit_length(byte) when byte >= 4, do: 3
  defp first_byte_bit_length(byte) when byte >= 2, do: 2
  defp first_byte_bit_length(_byte), do: 1

  defp integer_external_size_lower_bound(bits) when bits <= 8, do: 3
  defp integer_external_size_lower_bound(bits) when bits <= 32, do: 6

  defp integer_external_size_lower_bound(bits) do
    digits = div(bits + 7, 8)
    if digits <= 255, do: digits + 4, else: digits + 7
  end

  defp check_projected_budget(bytes, %{max_value_bytes: max_bytes} = state) do
    if bytes <= max_bytes, do: :ok, else: value_budget_error(bytes, state)
  end

  defp value_budget_error(bytes, %{max_value_bytes: max_bytes} = state) do
    {:error, {:value_budget_exceeded, bytes, max_bytes}, state}
  end

  defp fetch_var(vars, name) do
    case Map.fetch(vars, name) do
      {:ok, value} -> {:ok, value}
      :error when is_atom(name) -> Map.fetch(vars, Atom.to_string(name))
      :error -> :error
    end
  end

  defp normalize_known_name(value) when is_atom(value), do: value

  defp normalize_known_name(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp type_name(value) when is_binary(value), do: "binary"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_tuple(value), do: "tuple"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(nil), do: "nil"
  defp type_name(_value), do: "term"

  defp truthy?(value), do: value not in [false, nil]

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end
end
