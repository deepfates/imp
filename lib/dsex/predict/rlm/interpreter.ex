defmodule DSEx.Predict.RLM.Interpreter do
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

  @default_max_steps 10_000
  @default_max_output_chars 8_000
  @default_max_source_bytes 32_000
  @default_max_value_bytes 16_000_000
  @default_max_effects 100

  defstruct vars: %{},
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
            steps: 0

  @type t :: %__MODULE__{}

  @doc "Creates an interpreter with persistent variables and callback runtime."
  def new(vars, callbacks, runtime, opts \\ []) do
    vars = Map.new(vars)
    max_value_bytes = positive_option(opts, :max_value_bytes, @default_max_value_bytes)
    validate_initial_vars!(vars, max_value_bytes)

    %__MODULE__{
      vars: vars,
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
         {:ok, ast} <- parse(source),
         :ok <- check_ast_budget(ast, interpreter.max_steps) do
      case eval(ast, interpreter) do
        {:ok, value, next} ->
          {:ok, value, finish_transaction(next)}

        {:final, value, next} ->
          {:final, value, preserve_transaction(next, effect_results)}

        {:error, reason, next} ->
          {:error, reason, preserve_transaction(next, effect_results)}

        {:effect, request, _partial} ->
          if length(effect_results) >= interpreter.max_effects do
            {:error, {:effect_limit_exceeded, interpreter.max_effects},
             preserve_transaction(original, effect_results)}
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

  defp finish_transaction(interpreter),
    do: %{clean_transient(interpreter) | effect_journal: []}

  defp preserve_transaction(interpreter, effect_results),
    do: %{clean_transient(interpreter) | effect_journal: effect_results}

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

  defp eval_node(list, state) when is_list(list), do: eval_collection(list, state, & &1)

  defp eval_node({:%{}, _, pairs}, state) do
    eval_pairs(pairs, state, [])
  end

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
       when operator in [
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
            ] do
    eval_binary(operator, left, right, state)
  end

  defp eval_node({operator, _, [value]}, state) when operator in [:+, :-, :!, :not] do
    with {:ok, value, state} <- eval(value, state), do: apply_unary(operator, value, state)
  end

  defp eval_node({{:., _, [Access, :get]}, _, [container, key]}, state) do
    with {:ok, container, state} <- eval(container, state),
         {:ok, key, state} <- eval(key, state) do
      {:ok, access(container, key), state}
    end
  end

  defp eval_node({{:., _, [{:__aliases__, _, ["Access"]}, function]}, _, [container, key]}, state)
       when function in [:get, "get"] do
    with {:ok, container, state} <- eval(container, state),
         {:ok, key, state} <- eval(key, state) do
      {:ok, access(container, key), state}
    end
  end

  defp eval_node({{:., _, [{:__aliases__, _, [module]}, function]}, _, args}, state)
       when module in [:String, :Enum, "String", "Enum"] and
              (is_atom(function) or is_binary(function)) and is_list(args) do
    eval_allowlisted(module, function, args, state)
  end

  defp eval_node({:print, _, [expression]}, state) do
    with {:ok, value, state} <- eval(expression, state) do
      text = if is_binary(value), do: value, else: inspect(value)
      remaining = max(state.max_output_chars - String.length(state.output), 0)
      addition = String.slice(text, 0, remaining)
      {:ok, value, %{state | output: state.output <> addition}}
    end
  end

  defp eval_node({:submit, _, args}, state) when is_list(args) do
    with {:ok, values, state} <- eval_arguments(args, state),
         {:ok, output} <- submission(values) do
      {:final, output, state}
    else
      {:error, reason} -> {:error, reason, state}
      other -> other
    end
  end

  defp eval_node({name, _, args}, state)
       when (is_atom(name) or is_binary(name)) and is_list(args) do
    invoke_callback(name, args, state)
  end

  defp eval_node(ast, state), do: {:error, {:unsupported_expression, Macro.to_string(ast)}, state}

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

  defp eval_pairs([{key, value} | rest], state, pairs) do
    with {:ok, key, state} <- eval(key, state),
         {:ok, value, state} <- eval(value, state) do
      eval_pairs(rest, state, [{key, value} | pairs])
    end
  end

  defp eval_pairs(_pairs, state, _result), do: {:error, :invalid_map, state}

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
    body = Keyword.get(List.last(options, []), :do)

    if is_nil(body) do
      {:error, :for_requires_do_block, state}
    else
      eval_for_clauses(clauses, body, state, [])
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

  defp eval_for_clauses([{:<-, _, [{name, _, context}, enumerable]} | rest], body, state, results)
       when (is_atom(name) or is_binary(name)) and (is_atom(context) or is_nil(context)) do
    with {:ok, enumerable, state} <- eval(enumerable, state),
         true <- is_list(enumerable) or is_struct(enumerable, Range) do
      Enum.reduce_while(enumerable, {:ok, results, state}, fn item, {:ok, acc, current} ->
        current = %{current | vars: Map.put(current.vars, name, item)}

        case eval_for_clauses(rest, body, current, acc) do
          {:ok, produced, next} -> {:cont, {:ok, produced, next}}
          other -> {:halt, other}
        end
      end)
      |> restore_for_var(state, name)
    else
      false -> {:error, :for_requires_list_or_range, state}
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

  defp restore_for_var({:ok, values, next}, original, name) do
    {:ok, values, restore_for_var_binding(next, original, name)}
  end

  defp restore_for_var(
         {:error, {:value_budget_exceeded, _bytes, _max_bytes} = reason, next},
         original,
         name
       ) do
    {:error, reason, restore_for_var_binding(next, original, name)}
  end

  defp restore_for_var(other, _original, _name), do: other

  defp restore_for_var_binding(next, original, name) do
    vars =
      case fetch_var(original.vars, name) do
        {:ok, value} -> Map.put(next.vars, name, value)
        :error -> Map.delete(next.vars, name)
      end

    %{next | vars: vars}
  end

  @string_functions %{
    length: 1,
    slice: [2, 3],
    split: [1, 2],
    trim: 1,
    trim_leading: 1,
    trim_trailing: 1,
    downcase: 1,
    upcase: 1,
    replace: 3,
    contains?: 2,
    starts_with?: 2,
    ends_with?: 2,
    join: [1, 2]
  }
  @enum_functions %{
    at: [2, 3],
    slice: 2,
    take: 2,
    drop: 2,
    chunk_every: [2, 3],
    join: [1, 2],
    count: 1,
    reverse: 1,
    uniq: 1,
    concat: 1,
    member?: 2,
    min: 1,
    max: 1
  }

  defp eval_allowlisted(module, function, args, state) do
    module = normalize_known_name(module)
    function = normalize_known_name(function)
    allowed = if module == :String, do: @string_functions, else: @enum_functions
    target = if module == :String, do: String, else: Enum
    arities = List.wrap(Map.get(allowed, function))

    if length(args) in arities do
      with {:ok, values, state} <- eval_arguments(args, state) do
        try do
          with :ok <- check_transformation_budget(module, function, values, state) do
            {:ok, apply(target, function, values), state}
          end
        rescue
          error -> {:error, {:transformation_error, Exception.message(error)}, state}
        end
      end
    else
      {:error, {:function_not_allowed, module, function, length(args)}, state}
    end
  end

  defp invoke_callback(name, args, state) do
    effect =
      Map.get(state.callbacks, name) ||
        if(is_atom(name), do: Map.get(state.callbacks, Atom.to_string(name)))

    if effect do
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
    else
      {:error, {:function_not_allowed, name}, state}
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
