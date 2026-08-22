defmodule Imp.ProgramParameters do
  @moduledoc """
  Named optimizer lenses and typed parameter snapshots for Imp programs.

  `predictors/1` is the canonical lens used by instruction and demonstration
  optimizers. `snapshot/1`, `diff/2`, and `apply_changes/2` provide a bounded
  data-only contract: IDs are stable strings,
  values are JSON data, each change carries a content digest guard, and a
  multi-change update is committed atomically.

  Built-in predictors expose instruction, demos, and config parameters.
  Programs with persistent playbooks expose their serialized playbook. ReAct
  and ReActV2 also expose non-reserved tool descriptions and schemas; those
  lenses never serialize or replace a tool runner, the reserved `submit` tool,
  or a tool policy.
  """

  alias Imp.Optimizer.Parameter
  alias Imp.Optimizer.Parameter.Change
  alias Imp.Optimizer.Parameter.Set
  alias Imp.Optimizer.Component

  alias Imp.Predict.{
    Assertions,
    BestOfN,
    ChainOfThought,
    CodeAct,
    MultiChainComparison,
    Predict,
    ProgramOfThought,
    RAG,
    ReAct,
    ReActV2,
    Refine
  }

  @parameter_state_key :optimizer_parameter_set
  @keyword_marker "$imp_optimizer_keyword"

  @type name :: atom() | String.t()
  @type entry :: %{name: name(), predictor: struct()}
  @type playbook_entry :: %{name: name(), playbook: Imp.Playbook.t()}

  @doc "Returns every described, typed component exposed by a program."
  @spec components(struct()) :: [Component.t()]
  def components(%_module{} = program) do
    descriptors = descriptors(program)
    validate_descriptor_graph!(descriptors)
    Enum.map(descriptors, & &1.component)
  end

  @doc "Returns the textual instruction components consumed by GEPA."
  @spec instruction_components(struct()) :: [%{name: name(), component: Component.t()}]
  def instruction_components(%_module{} = program) do
    descriptors(program)
    |> validate_descriptor_graph!()
    |> Enum.flat_map(fn
      %{target: {:predictor_instruction, name}, component: component} ->
        [%{name: name, component: component}]

      _descriptor ->
        []
    end)
  end

  @spec predictors(struct()) :: [entry()]
  def predictors(%module{} = program) do
    case custom_predictor_contract!(module) do
      :custom ->
        program
        |> module.optimizer_predictors()
        |> normalize_custom_predictors!()

      :builtin ->
        builtin_predictors(program)
    end
  end

  @spec update_predictor(struct(), name(), (struct() -> struct())) :: struct()
  def update_predictor(%module{} = program, name, update) when is_function(update, 1) do
    case custom_predictor_contract!(module) do
      :custom ->
        updated = module.update_optimizer_predictor(program, name, update)
        validate_custom_predictor_update!(module, updated, name)

      :builtin when name == :main ->
        update_builtin_predictor(program, update)

      :builtin ->
        raise ArgumentError,
              "program #{inspect(module)} has no optimizer predictor named #{inspect(name)}"
    end
  end

  @spec put_instruction(struct(), name(), String.t()) :: struct()
  def put_instruction(program, name, instruction) when is_binary(instruction) do
    update_predictor(program, name, fn predictor ->
      Predict.with_signature(predictor, %{predictor.signature | instructions: instruction})
    end)
  end

  @spec put_demos(struct(), name(), [term()]) :: struct()
  def put_demos(program, name, demos) when is_list(demos) do
    update_predictor(program, name, &Predict.with_demos(&1, demos))
  end

  @doc "Functionally replaces one predictor's keyword config lens."
  @spec put_config(struct(), name(), keyword()) :: struct()
  def put_config(program, name, config) when is_list(config) do
    if Keyword.keyword?(config) do
      update_predictor(program, name, fn predictor -> %{predictor | config: config} end)
    else
      raise ArgumentError,
            "optimizer predictor config must be a keyword list, got: #{inspect(config)}"
    end
  end

  def put_config(_program, _name, config) do
    raise ArgumentError,
          "optimizer predictor config must be a keyword list, got: #{inspect(config)}"
  end

  @doc "Returns named persistent playbook parameters exposed by a program."
  @spec playbooks(struct()) :: [playbook_entry()]
  def playbooks(%module{} = program) do
    if callback_exported?(module, :optimizer_playbooks, 1) do
      program
      |> module.optimizer_playbooks()
      |> normalize_custom_playbooks!()
    else
      []
    end
  end

  @doc "Functionally updates one named persistent playbook parameter."
  @spec update_playbook(struct(), name(), (Imp.Playbook.t() -> Imp.Playbook.t())) :: struct()
  def update_playbook(%module{} = program, name, update) when is_function(update, 1) do
    if callback_exported?(module, :update_optimizer_playbook, 3) do
      updated = module.update_optimizer_playbook(program, name, update)

      unless match?(%Imp.Playbook{}, fetch_playbook!(updated, name)) do
        raise ArgumentError, "optimizer playbook update must return an Imp.Playbook"
      end

      updated
    else
      raise ArgumentError,
            "program #{inspect(module)} has no optimizer playbook named #{inspect(name)}"
    end
  end

  @doc "Replaces one named persistent playbook parameter."
  @spec put_playbook(struct(), name(), Imp.Playbook.t()) :: struct()
  def put_playbook(program, name, %Imp.Playbook{} = playbook) do
    update_playbook(program, name, fn _current -> playbook end)
  end

  @doc "Returns a revisioned, data-only snapshot of every exposed parameter."
  @spec snapshot(struct()) :: struct()
  def snapshot(%_module{} = program) do
    components = components(program)
    fresh = Set.new(program_id(program), Enum.map(components, & &1.parameter))

    case Imp.ProgramAccess.get_metadata(program, @parameter_state_key) do
      %Set{} = stored -> if(state_matches?(stored, fresh), do: stored, else: fresh)
      _other -> fresh
    end
  end

  @doc "Returns the typed parameters in the current snapshot."
  @spec parameters(struct()) :: [struct()]
  def parameters(program), do: snapshot(program).parameters

  @doc "Returns the complete optimizer-visible state as a stable JSON map."
  @spec values(struct()) :: %{required(String.t()) => Parameter.json_value()}
  def values(program), do: Map.new(parameters(program), &{&1.id, &1.value})

  @doc "Atomically replaces the complete optimizer-visible JSON state."
  @spec apply_values(struct(), map()) :: {:ok, struct()} | {:error, term()}
  def apply_values(%_module{} = program, values) when is_map(values) and not is_struct(values) do
    parameters = parameters(program)
    expected = MapSet.new(parameters, & &1.id)
    supplied = Map.keys(values) |> MapSet.new()

    if expected == supplied do
      changes =
        Enum.map(parameters, fn parameter ->
          Change.new(parameter.id, parameter.kind, Map.fetch!(values, parameter.id),
            base_digest: parameter.digest
          )
        end)

      apply_changes(program, changes)
    else
      {:error,
       {:parameter_value_ids_mismatch,
        %{
          missing: MapSet.difference(expected, supplied),
          unknown: MapSet.difference(supplied, expected)
        }}}
    end
  end

  def apply_values(_program, values), do: {:error, {:parameter_values_must_be_a_map, values}}

  @doc "Atomically replaces complete optimizer-visible state or raises."
  @spec apply_values!(struct(), map()) :: struct()
  def apply_values!(program, values) do
    case apply_values(program, values) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        raise ArgumentError, "cannot apply optimizer component values: #{inspect(reason)}"
    end
  end

  @doc "Returns only the minimal digest-guarded changes from `source` to `target`."
  @spec diff(struct(), struct()) :: [struct()]
  def diff(source, target), do: Set.diff(snapshot(source), snapshot(target))

  @doc "Applies every change or returns an error without yielding a partial program."
  @spec apply_changes(struct(), [struct() | map()]) :: {:ok, struct()} | {:error, term()}
  def apply_changes(program, changes) do
    with {:ok, updated, _snapshot} <- apply_changes_with_snapshot(program, changes) do
      {:ok, updated}
    end
  end

  @doc "Applies changes and also returns the committed parameter snapshot."
  @spec apply_changes_with_snapshot(struct(), [struct() | map()]) ::
          {:ok, struct(), struct()} | {:error, term()}
  def apply_changes_with_snapshot(%_module{} = program, changes) when is_list(changes) do
    current = snapshot(program)

    descriptors_by_id =
      descriptors(program)
      |> validate_descriptor_graph!()
      |> Map.new(&{&1.component.parameter.id, &1})

    with {:ok, normalized_changes} <- normalize_changes(changes),
         {:ok, committed} <- Set.apply_changes(current, normalized_changes),
         {:ok, prepared_changes} <- prepare_changes(normalized_changes, descriptors_by_id),
         {:ok, updated} <- apply_prepared_changes(program, prepared_changes) do
      updated = Imp.ProgramAccess.put_metadata(updated, @parameter_state_key, committed)
      {:ok, updated, committed}
    end
  end

  def apply_changes_with_snapshot(_program, changes),
    do: {:error, {:changes_must_be_a_list, changes}}

  @doc "Replaces a non-reserved ReAct or ReActV2 tool description."
  @spec put_tool_description(ReAct.t() | ReActV2.t(), name(), String.t()) ::
          ReAct.t() | ReActV2.t()
  def put_tool_description(program, name, description) when is_binary(description) do
    update_tool(program, name, fn tool -> %{tool | description: description} end)
  end

  @doc "Replaces a non-reserved ReAct or ReActV2 tool JSON schema."
  @spec put_tool_schema(ReAct.t() | ReActV2.t(), name(), map()) :: ReAct.t() | ReActV2.t()
  def put_tool_schema(program, name, schema) when is_map(schema) do
    schema = runtime_json_value!(schema, "tool schema")
    update_tool(program, name, fn tool -> %{tool | schema: schema} end)
  end

  def put_tool_schema(_program, _name, schema) do
    raise ArgumentError, "tool schemas must be JSON maps, got: #{inspect(schema)}"
  end

  defp descriptors(program) do
    predictor_descriptors(program) ++
      playbook_descriptors(program) ++
      tool_descriptors(program) ++
      custom_component_descriptors(program)
  end

  defp predictor_descriptors(program) do
    Enum.flat_map(predictors(program), fn %{name: name, predictor: predictor} ->
      segment = stable_segment!(name, "predictor name")
      prefix = "predictor/#{segment}"

      [
        %{
          component:
            component(
              prefix <> "/instruction",
              :instruction,
              predictor.signature.instructions,
              "Instructions for predictor #{name}",
              %{"type" => "string"}
            ),
          target: {:predictor_instruction, name}
        },
        %{
          component:
            component(
              prefix <> "/demos",
              :demos,
              demos_value!(predictor.demos),
              "Demonstrations for predictor #{name}",
              %{"type" => "array"}
            ),
          target: {:predictor_demos, name}
        },
        %{
          component:
            component(
              prefix <> "/config",
              :config,
              config_value!(predictor.config),
              "Generation configuration for predictor #{name}",
              %{"type" => "object"}
            ),
          target: {:predictor_config, name}
        }
      ]
    end)
  end

  defp playbook_descriptors(program) do
    Enum.map(playbooks(program), fn %{name: name, playbook: playbook} ->
      %{
        component:
          component(
            "playbook/#{stable_segment!(name, "playbook name")}",
            :playbook,
            Imp.Playbook.dump(playbook),
            "Persistent playbook #{name}",
            %{"type" => "object"}
          ),
        target: {:playbook, name}
      }
    end)
  end

  defp tool_descriptors(%ReAct{tools: tools}), do: tool_descriptors(tools)
  defp tool_descriptors(%ReActV2{tools: tools}), do: tool_descriptors(tools)

  defp tool_descriptors(tools) when is_map(tools) and not is_struct(tools) do
    tools
    |> tool_entries!()
    |> Enum.reject(fn {_name, tool} -> to_string(tool.name) == "submit" end)
    |> Enum.flat_map(fn {name, tool} ->
      segment = stable_segment!(name, "tool name")
      prefix = "tool/#{segment}"

      [
        %{
          component:
            component(
              prefix <> "/description",
              :tool_description,
              tool.description,
              "Provider-visible description for tool #{name}",
              %{"type" => "string", "minLength" => 1}
            ),
          target: {:tool_description, name}
        },
        %{
          component:
            component(
              prefix <> "/schema",
              :tool_schema,
              runtime_json_value!(tool.schema, "tool schema"),
              "Input schema for tool #{name}",
              %{"type" => "object"},
              [prefix <> "/description"]
            ),
          target: {:tool_schema, name}
        }
      ]
    end)
  end

  defp tool_descriptors(_program), do: []

  defp component(id, kind, value, description, constraints, dependencies \\ []) do
    Parameter.new(id, kind, value)
    |> Component.new(
      description: description,
      constraints: constraints,
      dependencies: dependencies
    )
  end

  defp custom_component_descriptors(%module{} = program) do
    case custom_component_contract!(module) do
      :none ->
        []

      :custom ->
        program
        |> module.optimizer_components()
        |> normalize_custom_components!()
        |> Enum.map(&%{component: &1, target: {:custom_component, &1.parameter.id}})
    end
  end

  defp validate_descriptor_graph!(descriptors) do
    ids = Enum.map(descriptors, & &1.component.parameter.id)

    if length(ids) != MapSet.size(MapSet.new(ids)) do
      raise ArgumentError, "optimizer component IDs must be unique strings"
    end

    known = MapSet.new(ids)

    Enum.each(descriptors, fn %{component: component} ->
      unknown = Enum.reject(component.dependencies, &MapSet.member?(known, &1))

      if unknown != [] do
        raise ArgumentError,
              "optimizer component #{inspect(component.parameter.id)} has unknown dependencies: #{inspect(unknown)}"
      end
    end)

    dependencies = Map.new(descriptors, &{&1.component.parameter.id, &1.component.dependencies})
    Enum.each(ids, &visit_dependency!(&1, dependencies, MapSet.new(), MapSet.new()))
    descriptors
  end

  defp visit_dependency!(id, dependencies, visiting, visited) do
    cond do
      MapSet.member?(visited, id) ->
        visited

      MapSet.member?(visiting, id) ->
        raise ArgumentError, "optimizer component dependencies contain a cycle at #{inspect(id)}"

      true ->
        visiting = MapSet.put(visiting, id)

        visited =
          Enum.reduce(Map.fetch!(dependencies, id), visited, fn dependency, current_visited ->
            visit_dependency!(dependency, dependencies, visiting, current_visited)
          end)

        MapSet.put(visited, id)
    end
  end

  defp state_matches?(%Set{id: id, parameters: stored}, %Set{id: id, parameters: fresh}) do
    Enum.map(stored, &{&1.id, &1.kind, &1.digest}) ==
      Enum.map(fresh, &{&1.id, &1.kind, &1.digest})
  end

  defp state_matches?(_stored, _fresh), do: false

  defp program_id(%module{} = program) do
    if callback_exported?(module, :optimizer_parameter_id, 1) do
      program |> module.optimizer_parameter_id() |> Parameter.validate_id!()
    else
      "program/" <> Atom.to_string(module)
    end
  end

  # Struct construction does not guarantee that its defining module has been
  # loaded. Ensure custom optimizer callbacks are discoverable in fresh BEAM
  # processes, including packaged consumers and clean benchmark captures.
  defp callback_exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp custom_predictor_contract!(module) do
    predictors? = callback_exported?(module, :optimizer_predictors, 1)
    updater? = callback_exported?(module, :update_optimizer_predictor, 3)

    case {predictors?, updater?} do
      {true, true} ->
        :custom

      {false, false} ->
        :builtin

      {true, false} ->
        raise ArgumentError,
              "program #{inspect(module)} implements optimizer_predictors/1 but is missing the paired Imp.Module update_optimizer_predictor/3 callback"

      {false, true} ->
        raise ArgumentError,
              "program #{inspect(module)} implements update_optimizer_predictor/3 but is missing the paired Imp.Module optimizer_predictors/1 callback"
    end
  end

  defp custom_component_contract!(module) do
    components? = callback_exported?(module, :optimizer_components, 1)
    updater? = callback_exported?(module, :update_optimizer_components, 2)

    case {components?, updater?} do
      {true, true} ->
        :custom

      {false, false} ->
        :none

      {true, false} ->
        raise ArgumentError,
              "program #{inspect(module)} implements optimizer_components/1 but is missing the paired Imp.Module update_optimizer_components/2 callback"

      {false, true} ->
        raise ArgumentError,
              "program #{inspect(module)} implements update_optimizer_components/2 but is missing the paired Imp.Module optimizer_components/1 callback"
    end
  end

  defp validate_custom_predictor_update!(module, %module{} = updated, name) do
    entries = updated |> module.optimizer_predictors() |> normalize_custom_predictors!()

    if Enum.any?(entries, &(&1.name == name)) do
      updated
    else
      raise ArgumentError,
            "update_optimizer_predictor/3 removed optimizer predictor #{inspect(name)}"
    end
  end

  defp validate_custom_predictor_update!(module, updated, _name) do
    raise ArgumentError,
          "update_optimizer_predictor/3 for #{inspect(module)} must return the same program struct, got: #{inspect(updated)}"
  end

  defp normalize_changes(changes) do
    changes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {change, index}, {:ok, normalized} ->
      case coerce_change(change) do
        {:ok, change} -> {:cont, {:ok, normalized ++ [change]}}
        {:error, message} -> {:halt, {:error, {:invalid_change, index, message}}}
      end
    end)
  end

  defp coerce_change(change) do
    {:ok, Change.coerce!(change)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp prepare_changes(changes, descriptors_by_id) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, prepared} ->
      case Map.fetch(descriptors_by_id, change.id) do
        :error ->
          {:halt, {:error, {:unknown_parameter, change.id}}}

        {:ok, descriptor} ->
          case validate_and_prepare_change(change, descriptor) do
            {:ok, prepared_change} -> {:cont, {:ok, prepared ++ [prepared_change]}}
            {:error, reason} -> {:halt, {:error, {:invalid_parameter_value, change.id, reason}}}
          end
      end
    end)
  end

  defp validate_and_prepare_change(change, descriptor) do
    Component.validate_value!(descriptor.component, change.value)
    prepare_change(change, descriptor)
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp prepare_change(%Change{} = change, %{target: {:custom_component, _id}} = descriptor),
    do: {:ok, {change, descriptor, change.value}}

  defp prepare_change(%Change{kind: :instruction, value: value} = change, descriptor)
       when is_binary(value),
       do: {:ok, {change, descriptor, value}}

  defp prepare_change(%Change{kind: :instruction}, _descriptor),
    do: {:error, "instructions must be strings"}

  defp prepare_change(%Change{kind: :demos, value: value} = change, descriptor) do
    {:ok, {change, descriptor, demos_from_value!(value)}}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp prepare_change(%Change{kind: :config, value: value} = change, descriptor) do
    {:ok, {change, descriptor, config_from_value!(value)}}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp prepare_change(%Change{kind: :playbook, value: value} = change, descriptor) do
    {:ok, {change, descriptor, Imp.Playbook.load!(value)}}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp prepare_change(%Change{kind: :tool_description, value: value} = change, descriptor)
       when is_binary(value),
       do: {:ok, {change, descriptor, value}}

  defp prepare_change(%Change{kind: :tool_description}, _descriptor),
    do: {:error, "tool descriptions must be strings"}

  defp prepare_change(%Change{kind: :tool_schema, value: value} = change, descriptor)
       when is_map(value),
       do: {:ok, {change, descriptor, value}}

  defp prepare_change(%Change{kind: :tool_schema}, _descriptor),
    do: {:error, "tool schemas must be JSON maps"}

  defp prepare_change(%Change{kind: kind}, _descriptor),
    do: {:error, "parameter kind #{inspect(kind)} has no program lens"}

  defp apply_prepared_changes(program, prepared_changes) do
    {custom, builtin} =
      Enum.split_with(prepared_changes, fn {_change, descriptor, _value} ->
        match?({:custom_component, _id}, descriptor.target)
      end)

    updated =
      Enum.reduce(builtin, program, fn {_change, descriptor, value}, current ->
        apply_descriptor(current, descriptor.target, value)
      end)

    updated = apply_custom_changes(updated, custom)

    {:ok, updated}
  rescue
    error in ArgumentError -> {:error, {:parameter_apply_failed, Exception.message(error)}}
  end

  defp apply_custom_changes(program, []), do: program

  defp apply_custom_changes(%module{} = program, changes) do
    replacements =
      Map.new(changes, fn {_change, %{target: {:custom_component, id}}, value} -> {id, value} end)

    case module.update_optimizer_components(program, replacements) do
      %{__struct__: ^module} = updated ->
        current =
          Map.new(
            custom_component_descriptors(updated),
            &{&1.component.parameter.id, &1.component}
          )

        Enum.each(replacements, fn {id, expected} ->
          case Map.fetch(current, id) do
            {:ok, %{parameter: %{value: ^expected}}} ->
              :ok

            {:ok, _component} ->
              raise ArgumentError, "custom component update did not apply #{inspect(id)}"

            :error ->
              raise ArgumentError, "custom component update removed #{inspect(id)}"
          end
        end)

        updated

      other ->
        raise ArgumentError,
              "update_optimizer_components/2 for #{inspect(module)} must return the same program struct, got: #{inspect(other)}"
    end
  end

  defp apply_descriptor(program, {:predictor_instruction, name}, value),
    do: put_instruction(program, name, value)

  defp apply_descriptor(program, {:predictor_demos, name}, value),
    do: put_demos(program, name, value)

  defp apply_descriptor(program, {:predictor_config, name}, value),
    do: put_config(program, name, value)

  defp apply_descriptor(program, {:playbook, name}, value), do: put_playbook(program, name, value)

  defp apply_descriptor(program, {:tool_description, name}, value),
    do: put_tool_description(program, name, value)

  defp apply_descriptor(program, {:tool_schema, name}, value),
    do: put_tool_schema(program, name, value)

  defp demos_value!(demos) when is_list(demos), do: Enum.map(demos, &demo_value!/1)

  defp demos_value!(demos),
    do: raise(ArgumentError, "predictor demos must be a list, got: #{inspect(demos)}")

  defp demo_value!(%Imp.Example{} = demo) do
    %{
      "demos" => Enum.map(demo.demos, &demo_value!/1),
      "fields" => runtime_json_value!(Imp.Example.to_map(demo), "demo fields"),
      "input_keys" => Enum.map(demo.input_keys || [], &json_key!(&1, "demo input key"))
    }
  end

  defp demo_value!(demo), do: demo |> Imp.Example.new() |> demo_value!()

  defp demos_from_value!(value) when is_list(value), do: Enum.map(value, &demo_from_value!/1)

  defp demos_from_value!(value),
    do: raise(ArgumentError, "predictor demos must be a JSON list, got: #{inspect(value)}")

  defp demo_from_value!(
         %{"demos" => demos, "fields" => fields, "input_keys" => input_keys} = value
       )
       when map_size(value) == 3 and is_map(fields) and is_list(input_keys) and is_list(demos) do
    unless Enum.all?(input_keys, &is_binary/1) do
      raise ArgumentError, "demo input_keys must be strings"
    end

    fields =
      Map.new(fields, fn {key, nested} ->
        {existing_atom_or_string(key), json_to_runtime!(nested, "demo field")}
      end)

    demo = Imp.Example.new(fields)
    demo = if input_keys == [], do: demo, else: Imp.Example.with_inputs(demo, input_keys)
    Imp.Example.with_demos(demo, Enum.map(demos, &demo_from_value!/1))
  end

  defp demo_from_value!(value),
    do: raise(ArgumentError, "invalid JSON demo representation: #{inspect(value)}")

  defp config_value!(config) when is_list(config) do
    if Keyword.keyword?(config) do
      config
      |> Map.new()
      |> runtime_json_value!("predictor config")
    else
      raise ArgumentError, "predictor config must be a keyword list, got: #{inspect(config)}"
    end
  end

  defp config_value!(config),
    do: raise(ArgumentError, "predictor config must be a keyword list, got: #{inspect(config)}")

  defp config_from_value!(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn
      {key, nested} when is_binary(key) ->
        case existing_atom_or_string(key) do
          atom when is_atom(atom) ->
            {atom, json_to_runtime!(nested, "predictor config")}

          _string ->
            raise ArgumentError,
                  "predictor config key #{inspect(key)} is not an existing atom and cannot be applied safely"
        end
    end)
  end

  defp config_from_value!(value),
    do: raise(ArgumentError, "predictor config must be a JSON object, got: #{inspect(value)}")

  defp runtime_json_value!(value, context) do
    normalized = runtime_to_json!(value, context)
    Parameter.validate_value!(normalized)
    normalized
  end

  defp runtime_to_json!(%Imp.Example{} = value, _context), do: demo_value!(value)

  defp runtime_to_json!(value, _context)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value),
       do: value

  defp runtime_to_json!(value, context) when is_list(value) do
    if Keyword.keyword?(value) do
      %{
        @keyword_marker =>
          Enum.map(value, fn {key, nested} ->
            [Atom.to_string(key), runtime_to_json!(nested, context)]
          end)
      }
    else
      Enum.map(value, &runtime_to_json!(&1, context))
    end
  end

  defp runtime_to_json!(value, context) when is_map(value) and not is_struct(value) do
    entries =
      Enum.map(value, fn {key, nested} ->
        key = json_key!(key, "#{context} key")
        {key, runtime_to_json!(nested, context)}
      end)

    keys = Enum.map(entries, &elem(&1, 0))

    cond do
      @keyword_marker in keys ->
        raise ArgumentError, "#{context} uses reserved key #{@keyword_marker}"

      length(keys) == MapSet.size(MapSet.new(keys)) ->
        Map.new(entries)

      true ->
        raise ArgumentError, "#{context} contains colliding atom and string keys"
    end
  end

  defp runtime_to_json!(value, context) do
    raise ArgumentError,
          "#{context} cannot be represented as JSON-safe optimizer data: #{inspect(value)}"
  end

  defp json_to_runtime!(%{@keyword_marker => entries} = value, context)
       when map_size(value) == 1 and is_list(entries) do
    Enum.map(entries, fn
      [key, nested] when is_binary(key) ->
        case existing_atom_or_string(key) do
          atom when is_atom(atom) ->
            {atom, json_to_runtime!(nested, context)}

          _string ->
            raise ArgumentError,
                  "#{context} keyword key #{inspect(key)} is not an existing atom"
        end

      entry ->
        raise ArgumentError,
              "#{context} contains an invalid encoded keyword entry: #{inspect(entry)}"
    end)
  end

  defp json_to_runtime!(value, context) when is_list(value),
    do: Enum.map(value, &json_to_runtime!(&1, context))

  defp json_to_runtime!(value, context) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, json_to_runtime!(nested, context)} end)

  defp json_to_runtime!(value, _context), do: value

  defp update_tool(%ReAct{} = program, name, update) do
    program.tools
    |> replace_tool(name, update)
    |> then(&ReAct.with_tools(program, &1))
  end

  defp update_tool(%ReActV2{} = program, name, update) do
    program.tools
    |> replace_tool(name, update)
    |> then(&ReActV2.with_tools(program, &1))
  end

  defp update_tool(program, _name, _update) do
    raise ArgumentError,
          "tool parameters are only available for Imp.Predict.ReAct and Imp.Predict.ReActV2, got: #{inspect(program.__struct__)}"
  end

  defp replace_tool(tools, name, update) do
    {key, tool} = fetch_tool!(tools, name)

    if to_string(tool.name) == "submit" do
      raise ArgumentError, "submit is reserved and cannot be optimized"
    end

    Map.put(tools, key, update.(tool))
  end

  defp fetch_tool!(tools, name) do
    expected = stable_segment!(name, "tool name")

    case tool_entries!(tools)
         |> Enum.find(fn {key, _tool} -> stable_segment!(key, "tool name") == expected end) do
      nil -> raise ArgumentError, "unknown optimizer tool #{inspect(name)}"
      entry -> entry
    end
  end

  defp tool_entries!(tools) when is_map(tools) do
    entries =
      Enum.map(tools, fn
        {name, %Imp.Tool{} = tool} -> {name, tool}
        entry -> raise ArgumentError, "invalid ReAct tool entry: #{inspect(entry)}"
      end)

    stable_names = Enum.map(entries, fn {name, _tool} -> stable_segment!(name, "tool name") end)

    if length(stable_names) == MapSet.size(MapSet.new(stable_names)) do
      entries
    else
      raise ArgumentError, "ReAct tool names collide after string normalization"
    end
  end

  defp stable_segment!(name, context) when is_atom(name),
    do: name |> Atom.to_string() |> stable_segment!(context)

  defp stable_segment!(name, context) when is_binary(name) do
    if name != "" and String.valid?(name) do
      name
      |> String.replace("%", "%25")
      |> String.replace("/", "%2F")
    else
      raise ArgumentError, "#{context} must be a non-empty UTF-8 atom or string"
    end
  end

  defp stable_segment!(name, context) do
    raise ArgumentError, "#{context} must be an atom or string, got: #{inspect(name)}"
  end

  defp json_key!(name, _context) when is_atom(name), do: Atom.to_string(name)

  defp json_key!(name, context) when is_binary(name) do
    if String.valid?(name) do
      name
    else
      raise ArgumentError, "#{context} must be a UTF-8 atom or string"
    end
  end

  defp json_key!(name, context) do
    raise ArgumentError, "#{context} must be an atom or string, got: #{inspect(name)}"
  end

  defp existing_atom_or_string(value) when is_atom(value), do: value

  defp existing_atom_or_string(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp builtin_predictors(program) do
    case builtin_predictor(program) do
      %Predict{} = predictor -> [%{name: :main, predictor: predictor}]
      nil -> []
    end
  end

  defp builtin_predictor(%Predict{} = predictor), do: predictor
  defp builtin_predictor(%ChainOfThought{predict: predictor}), do: predictor
  defp builtin_predictor(%ProgramOfThought{predict: predictor}), do: predictor
  defp builtin_predictor(%CodeAct{program_of_thought: program}), do: builtin_predictor(program)
  defp builtin_predictor(%RAG{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%Assertions{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%ReAct{react: predictor}), do: predictor
  defp builtin_predictor(%ReActV2{react: predictor}), do: predictor
  defp builtin_predictor(%BestOfN{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%Refine{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%MultiChainComparison{predict: predictor}), do: predictor
  defp builtin_predictor(_program), do: nil

  defp update_builtin_predictor(%Predict{} = program, update), do: update.(program)

  defp update_builtin_predictor(%ChainOfThought{predict: predictor} = program, update),
    do: %{program | predict: update.(predictor)}

  defp update_builtin_predictor(%ProgramOfThought{predict: predictor} = program, update),
    do: %{program | predict: update.(predictor)}

  defp update_builtin_predictor(%CodeAct{program_of_thought: inner} = program, update),
    do: %{program | program_of_thought: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%RAG{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%Assertions{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%ReAct{react: predictor} = program, update),
    do: %{program | react: update.(predictor)}

  defp update_builtin_predictor(%ReActV2{react: predictor} = program, update),
    do: %{program | react: update.(predictor)}

  defp update_builtin_predictor(%BestOfN{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%Refine{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%MultiChainComparison{predict: predictor} = program, update),
    do: %{program | predict: update.(predictor)}

  defp update_builtin_predictor(%module{}, _update) do
    raise ArgumentError,
          "program #{inspect(module)} does not expose optimizer predictors; implement optimizer_predictors/1 and update_optimizer_predictor/3"
  end

  defp normalize_custom_predictors!(predictors) when is_list(predictors) do
    entries =
      Enum.map(predictors, fn
        {name, %Predict{} = predictor} -> %{name: name, predictor: predictor}
        %{name: name, predictor: %Predict{} = predictor} -> %{name: name, predictor: predictor}
        other -> raise ArgumentError, "invalid optimizer predictor entry: #{inspect(other)}"
      end)

    names = Enum.map(entries, & &1.name)
    normalized_names = Enum.map(names, &{name_type(&1), to_string(&1)})

    if length(normalized_names) == MapSet.size(MapSet.new(normalized_names)),
      do: entries,
      else: raise(ArgumentError, "optimizer predictor names must be unique")
  end

  defp normalize_custom_predictors!(other) do
    raise ArgumentError,
          "optimizer_predictors/1 must return a list, got: #{inspect(other)}"
  end

  defp normalize_custom_playbooks!(playbooks) when is_list(playbooks) do
    entries =
      Enum.map(playbooks, fn
        {name, %Imp.Playbook{} = playbook} -> %{name: name, playbook: playbook}
        %{name: name, playbook: %Imp.Playbook{} = playbook} -> %{name: name, playbook: playbook}
        other -> raise ArgumentError, "invalid optimizer playbook entry: #{inspect(other)}"
      end)

    names = Enum.map(entries, & &1.name)
    normalized_names = Enum.map(names, &{name_type(&1), to_string(&1)})

    if length(normalized_names) == MapSet.size(MapSet.new(normalized_names)),
      do: entries,
      else: raise(ArgumentError, "optimizer playbook names must be unique")
  end

  defp normalize_custom_playbooks!(other) do
    raise ArgumentError,
          "optimizer_playbooks/1 must return a list, got: #{inspect(other)}"
  end

  defp normalize_custom_components!(components) when is_list(components) do
    Enum.map(components, fn
      %Component{} = component -> component
      other -> raise ArgumentError, "invalid optimizer component entry: #{inspect(other)}"
    end)
  end

  defp normalize_custom_components!(other) do
    raise ArgumentError,
          "optimizer_components/1 must return a list of Imp.Optimizer.Component values, got: #{inspect(other)}"
  end

  defp fetch_playbook!(program, name) do
    case Enum.find(playbooks(program), &(&1.name == name)) do
      %{playbook: playbook} -> playbook
      nil -> raise ArgumentError, "optimizer playbook update removed #{inspect(name)}"
    end
  end

  defp name_type(name) when is_atom(name), do: :atom
  defp name_type(name) when is_binary(name), do: :string
end
