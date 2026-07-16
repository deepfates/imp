defmodule Mix.Tasks.Imp.PublicApi do
  @moduledoc false

  use Mix.Task

  @shortdoc "Generate or check the curated packaged public API manifest"
  @default_manifest_path "priv/public_api.json"
  @default_policy_path "priv/public_api_policy.json"
  @supported_snapshot_versions [2, 3]
  @snapshot_required_fields ~w(schema_version app package_version scope categories modules excluded_modules)
  @module_required_fields ~w(module source category kind functions macros callbacks types struct_fields)
  @signature_kinds ~w(callbacks functions types)
  @generated_exports MapSet.new([
                       "__info__/1",
                       "__protocol__/1",
                       "__struct__/0",
                       "__struct__/1",
                       "behaviour_info/1",
                       "child_spec/1",
                       "module_info/0",
                       "module_info/1"
                     ])

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    load_application!()

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [check: :boolean, diff: :boolean, out: :string, policy: :string]
      )

    if invalid != [],
      do: Mix.raise("invalid arguments: #{inspect(argv ++ invalid)}")

    if Keyword.get(opts, :diff, false) do
      run_diff!(argv, opts)
    else
      if argv != [], do: Mix.raise("invalid arguments: #{inspect(argv)}")

      manifest_path = Keyword.get(opts, :out, @default_manifest_path)
      contents = encoded_manifest(policy: Keyword.get(opts, :policy, @default_policy_path))

      if Keyword.get(opts, :check, false) do
        check!(manifest_path, contents)
      else
        File.mkdir_p!(Path.dirname(manifest_path))
        File.write!(manifest_path, contents)
        Mix.shell().info("public API manifest: #{manifest_path}")
      end
    end
  end

  @doc false
  def manifest(opts \\ []) do
    load_application!()

    package_files =
      Mix.Project.config()
      |> Keyword.fetch!(:package)
      |> Keyword.fetch!(:files)
      |> MapSet.new()

    modules = packaged_documented_modules(package_files)
    policy = load_policy!(Keyword.get(opts, :policy, @default_policy_path))
    validate_policy!(policy, modules)

    {public_modules, excluded_modules} =
      modules
      |> Enum.map(fn module -> {module, classify!(inspect(module), policy)} end)
      |> Enum.sort_by(fn {module, _category} -> inspect(module) end)
      |> Enum.reduce({[], []}, fn {module, category}, {public, excluded} ->
        entry = module_entry(module, category, policy)

        if category == "internal" do
          {public, [Map.take(entry, ["category", "module", "source"]) | excluded]}
        else
          {[entry | public], excluded}
        end
      end)

    %{
      "schema_version" => 3,
      "app" => "imp",
      "package_version" => Mix.Project.config()[:version],
      "scope" =>
        "Curated Imp API compiled from package-shipped sources. Exports come from non-hidden documentation entries; callbacks, types, and struct fields are category- and policy-gated.",
      "categories" => category_definitions(policy),
      "modules" => Enum.reverse(public_modules),
      "excluded_modules" => Enum.reverse(excluded_modules)
    }
  end

  @doc false
  def encoded_manifest(opts \\ []) do
    opts
    |> manifest()
    |> ordered_json_term()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc false
  def classify_module(module_name, policy \\ nil) when is_binary(module_name) do
    policy = policy || load_policy!(@default_policy_path)
    classify!(module_name, policy)
  end

  @doc "Classifies the API changes between two public API manifests."
  def api_diff(previous, current) do
    previous = validate_snapshot!(previous, "previous")
    current = validate_snapshot!(current, "current")
    previous_modules = module_map(previous)
    current_modules = module_map(current)

    breaking_changes =
      removed_modules(previous_modules, current_modules) ++
        breaking_module_changes(previous_modules, current_modules)

    additive_changes =
      added_modules(previous_modules, current_modules) ++
        added_members(previous_modules, current_modules)

    metadata_changes = metadata_changes(previous, current)

    classification =
      cond do
        breaking_changes != [] -> "breaking"
        additive_changes != [] -> "additive"
        metadata_changes != [] -> "metadata_only"
        true -> "no_change"
      end

    %{
      "schema_version" => 1,
      "classification" => classification,
      "breaking_changes" => sort_changes(breaking_changes),
      "additive_changes" => sort_changes(additive_changes),
      "metadata_changes" => sort_changes(metadata_changes),
      "semver" => semver_guidance(previous["package_version"], classification)
    }
  end

  @doc "Returns the deterministic SemVer guidance for an API diff classification."
  def semver_guidance(version, classification) when is_binary(version) do
    {major, minor, patch} = parse_version!(version)

    {bump, recommended} =
      case {classification, major} do
        {"breaking", 0} ->
          {"minor", "0.#{minor + 1}.0"}

        {"breaking", _} ->
          {"major", "#{major + 1}.0.0"}

        {kind, 0} when kind in ["additive", "metadata_only"] ->
          {"patch", "0.#{minor}.#{patch + 1}"}

        {kind, _} when kind in ["additive"] ->
          {"minor", "#{major}.#{minor + 1}.0"}

        {"metadata_only", _} ->
          {"patch", "#{major}.#{minor}.#{patch + 1}"}

        {"no_change", _} ->
          {"none", version}

        {unknown, _} ->
          Mix.raise("unknown public API diff classification: #{inspect(unknown)}")
      end

    %{
      "bump" => bump,
      "recommended_version" => recommended,
      "pre_1_0" => major == 0,
      "policy" =>
        if major == 0 do
          "Before 1.0.0, breaking changes use the next minor version; additive and metadata-only changes use a patch."
        else
          "After 1.0.0, breaking changes use a major version, additive changes a minor version, and metadata-only changes a patch."
        end
    }
  end

  def semver_guidance(nil, _classification) do
    %{
      "bump" => "unknown",
      "recommended_version" => nil,
      "pre_1_0" => nil,
      "policy" =>
        "No prior package version was supplied; classify the diff without inventing a release baseline."
    }
  end

  defp check!(path, expected) do
    case File.read(path) do
      {:ok, ^expected} ->
        Mix.shell().info("public API manifest is current: #{path}")

      {:ok, _other} ->
        Mix.raise("public API manifest drifted; run mix imp.public_api and review #{path}")

      {:error, reason} ->
        Mix.raise("public API manifest is unavailable at #{path}: #{inspect(reason)}")
    end
  end

  defp packaged_documented_modules(package_files) do
    :imp
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and MapSet.member?(package_files, source_path(module)) and
        documented_module?(module)
    end)
  end

  defp documented_module?(module) do
    match?({:docs_v1, _, _, _, %{"en" => _}, _, _}, Code.fetch_docs(module))
  end

  defp module_entry(module, category, policy) do
    category_policy = Map.fetch!(policy["categories"], category)
    docs = public_doc_entries(module)

    %{
      "module" => inspect(module),
      "source" => source_path(module),
      "category" => category,
      "kind" => module_kind(module),
      "functions" => exports(docs, :function, module, policy),
      "macros" => exports(docs, :macro, module, policy),
      "signatures" => signatures(docs),
      "callbacks" => callbacks(docs, module, category_policy),
      "types" => types(docs, module, category_policy),
      "struct_fields" => struct_fields(module)
    }
  end

  defp public_doc_entries(module) do
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(module)

    Enum.reject(entries, fn {_id, _anno, _signatures, doc, metadata} ->
      doc == :hidden or Map.get(metadata, :hidden, false) or Map.get(metadata, "hidden", false)
    end)
  end

  defp exports(entries, kind, module, policy) do
    excluded =
      policy
      |> Map.get("export_exclusions", %{})
      |> Map.get(inspect(module), [])
      |> MapSet.new()

    entries
    |> Enum.flat_map(fn
      {{^kind, name, arity}, _anno, _signatures, _doc, _metadata} ->
        export = "#{name}/#{arity}"

        if MapSet.member?(@generated_exports, export) or MapSet.member?(excluded, export),
          do: [],
          else: [export]

      _entry ->
        []
    end)
    |> Enum.sort()
  end

  defp signatures(entries) do
    entries
    |> Enum.flat_map(fn
      {{kind, name, arity}, _anno, entry_signatures, _doc, _metadata}
      when kind in [:function, :macro, :callback, :macrocallback, :type] ->
        [{kind_name(kind), "#{name}/#{arity}", Enum.map(entry_signatures, &signature/1)}]

      _entry ->
        []
    end)
    |> Enum.group_by(fn {kind, _export, _signatures} -> kind end, fn {_kind, export,
                                                                      entry_signatures} ->
      {export, entry_signatures}
    end)
    |> Enum.map(fn {kind, values} ->
      {kind,
       values
       |> Enum.sort_by(&elem(&1, 0))
       |> Map.new()}
    end)
    |> Map.new()
  end

  defp kind_name(:function), do: "functions"
  defp kind_name(:macro), do: "macros"
  defp kind_name(:callback), do: "callbacks"
  defp kind_name(:macrocallback), do: "callbacks"
  defp kind_name(:type), do: "types"

  defp signature(value) when is_binary(value), do: value
  defp signature(value), do: inspect(value, pretty: false, limit: :infinity)

  defp callbacks(_entries, _module, %{"callbacks" => false}), do: []

  defp callbacks(_entries, module, %{"callbacks" => true}) do
    if function_exported?(module, :behaviour_info, 1) do
      optional_callbacks = module.behaviour_info(:optional_callbacks) |> MapSet.new()

      module.behaviour_info(:callbacks)
      |> Enum.map(fn {name, arity} ->
        %{
          "name" => "#{name}/#{arity}",
          "optional" => MapSet.member?(optional_callbacks, {name, arity})
        }
      end)
      |> Enum.sort_by(& &1["name"])
    else
      []
    end
  end

  defp types(_entries, _module, %{"types" => false}), do: []

  defp types(entries, module, %{"types" => true}) do
    documented_types =
      entries
      |> Enum.flat_map(fn
        {{:type, name, arity}, _anno, _signatures, _doc, _metadata} -> [{name, arity}]
        _entry -> []
      end)
      |> MapSet.new()

    case Code.Typespec.fetch_types(module) do
      {:ok, types} ->
        types
        |> Enum.flat_map(fn
          {kind, {name, _definition, args}} when kind in [:type, :opaque] and is_list(args) ->
            if MapSet.member?(documented_types, {name, length(args)}) do
              [%{"kind" => Atom.to_string(kind), "name" => "#{name}/#{length(args)}"}]
            else
              []
            end

          _other ->
            []
        end)
        |> Enum.sort_by(&{&1["name"], &1["kind"]})

      :error ->
        []
    end
  end

  defp struct_fields(module) do
    if function_exported?(module, :__struct__, 0) do
      module.__struct__()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__struct__))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()
    else
      []
    end
  end

  defp module_kind(module) do
    cond do
      function_exported?(module, :__protocol__, 1) -> "protocol"
      function_exported?(module, :__struct__, 0) -> "struct"
      callback_module?(module) -> "behaviour"
      true -> "module"
    end
  end

  defp callback_module?(module) do
    public_doc_entries(module)
    |> Enum.any?(fn
      {{kind, _name, _arity}, _anno, _signatures, _doc, _metadata}
      when kind in [:callback, :macrocallback] ->
        true

      _entry ->
        false
    end)
  end

  defp load_policy!(path) do
    case File.read(path) do
      {:ok, contents} ->
        Jason.decode!(contents)

      {:error, reason} ->
        Mix.raise("public API policy is unavailable at #{path}: #{inspect(reason)}")
    end
  rescue
    error in Jason.DecodeError ->
      Mix.raise("public API policy is invalid JSON at #{path}: #{Exception.message(error)}")
  end

  defp validate_policy!(policy, modules) do
    unless policy["schema_version"] == 1 and
             policy["rule_resolution"] == "most_specific_match" and
             is_map(policy["categories"]) and is_list(policy["rules"]) do
      Mix.raise(
        "public API policy must contain schema_version 1, rule_resolution most_specific_match, categories, and rules"
      )
    end

    module_names = modules |> Enum.map(&inspect/1) |> MapSet.new()
    categories = Map.keys(policy["categories"]) |> MapSet.new()

    Enum.each(policy["rules"], fn rule ->
      category = Map.fetch!(rule, "category")

      unless is_list(Map.get(rule, "modules", [])) and is_list(Map.get(rule, "prefixes", [])) do
        Mix.raise("public API policy rule #{inspect(rule)} must use module and prefix lists")
      end

      unless MapSet.member?(categories, category) do
        Mix.raise("public API policy uses unknown category #{inspect(category)}")
      end

      Enum.each(Map.get(rule, "modules", []), fn module_name ->
        unless MapSet.member?(module_names, module_name) do
          Mix.raise("public API policy names missing packaged documented module #{module_name}")
        end
      end)
    end)

    Enum.each(policy["categories"], fn {category, config} ->
      unless is_boolean(config["callbacks"]) and is_boolean(config["types"]) do
        Mix.raise(
          "public API policy category #{inspect(category)} must declare callbacks and types"
        )
      end
    end)

    documented_exports =
      Map.new(modules, fn module ->
        exports =
          public_doc_entries(module)
          |> Enum.flat_map(fn
            {{kind, name, arity}, _anno, _signatures, _doc, _metadata}
            when kind in [:function, :macro] ->
              ["#{name}/#{arity}"]

            _entry ->
              []
          end)
          |> MapSet.new()

        {inspect(module), exports}
      end)

    Enum.each(Map.get(policy, "export_exclusions", %{}), fn {module_name, exports} ->
      available = Map.get(documented_exports, module_name)

      if is_nil(available) do
        Mix.raise("public API policy names missing packaged documented module #{module_name}")
      end

      Enum.each(exports, fn export ->
        unless MapSet.member?(available, export) do
          Mix.raise(
            "public API policy names missing documented export #{export} on #{module_name}"
          )
        end
      end)
    end)
  end

  defp classify!(module_name, policy) do
    matches =
      Enum.flat_map(policy["rules"], fn rule ->
        exact_match =
          if module_name in Map.get(rule, "modules", []),
            do: [{2, 0, rule["category"]}],
            else: []

        prefix_matches =
          rule
          |> Map.get("prefixes", [])
          |> Enum.filter(&module_prefix_match?(module_name, &1))
          |> Enum.map(&{1, String.length(&1), rule["category"]})

        exact_match ++ prefix_matches
      end)

    case matches do
      [] ->
        Mix.raise(
          "public API policy leaves packaged documented module unclassified: #{module_name}"
        )

      matches ->
        best_specificity = matches |> Enum.map(&{elem(&1, 0), elem(&1, 1)}) |> Enum.max()

        categories =
          matches
          |> Enum.filter(fn {kind, length, _category} -> {kind, length} == best_specificity end)
          |> Enum.map(&elem(&1, 2))
          |> Enum.uniq()

        case categories do
          [category] ->
            category

          categories ->
            Mix.raise(
              "public API policy has ambiguous #{policy["rule_resolution"]} overlap for #{module_name}: #{inspect(categories)}"
            )
        end
    end
  end

  defp module_prefix_match?(module_name, prefix) do
    prefix = String.trim_trailing(prefix, ".")
    module_name == prefix or String.starts_with?(module_name, prefix <> ".")
  end

  defp run_diff!(paths, opts) do
    {previous, current} =
      case paths do
        [previous_path] ->
          {read_snapshot!(previous_path),
           manifest(policy: Keyword.get(opts, :policy, @default_policy_path))}

        [previous_path, current_path] ->
          {read_snapshot!(previous_path), read_snapshot!(current_path)}

        _ ->
          Mix.raise("--diff expects OLD_MANIFEST or OLD_MANIFEST NEW_MANIFEST")
      end

    diff = api_diff(previous, current)
    Mix.shell().info(Jason.encode!(ordered_json_term(diff), pretty: true))

    if Keyword.get(opts, :check, false) and diff["classification"] == "breaking" do
      Mix.raise("public API diff contains breaking changes")
    end
  end

  defp read_snapshot!(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, snapshot} ->
            validate_snapshot!(snapshot, path)

          {:error, error} ->
            Mix.raise("invalid public API snapshot #{path}: #{Exception.message(error)}")
        end

      {:error, reason} ->
        Mix.raise("public API snapshot is unavailable at #{path}: #{inspect(reason)}")
    end
  end

  defp validate_snapshot!(snapshot, label) when is_map(snapshot) do
    require_fields!(snapshot, @snapshot_required_fields, label)

    schema_version = snapshot["schema_version"]

    unless is_integer(schema_version) and schema_version in @supported_snapshot_versions do
      invalid_snapshot!(label, "schema_version must be one of 2 or 3")
    end

    validate_string_field!(snapshot, "app", label)
    validate_string_field!(snapshot, "package_version", label)
    validate_string_field!(snapshot, "scope", label)

    unless snapshot["app"] == "imp" do
      invalid_snapshot!(label, ~s(app must be "imp"))
    end

    unless valid_semver?(snapshot["package_version"]) do
      invalid_snapshot!(label, "package_version must be a valid SemVer string")
    end

    categories = snapshot["categories"]

    unless is_list(categories) do
      invalid_snapshot!(label, "categories must be a list")
    end

    category_names = validate_categories!(categories, schema_version, label)
    module_names = validate_modules!(snapshot["modules"], schema_version, category_names, label)

    excluded_names =
      validate_excluded_modules!(snapshot["excluded_modules"], category_names, label)

    duplicate_names = duplicate_values(module_names ++ excluded_names)

    if duplicate_names != [] do
      invalid_snapshot!(
        label,
        "module names must be unique across modules and excluded_modules: #{inspect(duplicate_names)}"
      )
    end

    snapshot
  end

  defp validate_snapshot!(_snapshot, label),
    do: invalid_snapshot!(label, "must contain a JSON object")

  defp require_fields!(map, fields, label) do
    Enum.each(fields, fn field ->
      unless Map.has_key?(map, field) do
        invalid_snapshot!(label, "missing required field #{inspect(field)}")
      end
    end)
  end

  defp validate_string_field!(map, field, label) do
    unless is_binary(map[field]) do
      invalid_snapshot!(label, "#{field} must be a string")
    end
  end

  defp validate_categories!(categories, schema_version, label) do
    names =
      categories
      |> Enum.with_index()
      |> Enum.map(fn {category, index} ->
        category_label = "#{label}.categories[#{index}]"

        unless is_map(category), do: invalid_snapshot!(category_label, "must be an object")
        require_fields!(category, ~w(name callbacks types), category_label)
        validate_string_field!(category, "name", category_label)

        unless is_boolean(category["callbacks"]) do
          invalid_snapshot!(category_label, "callbacks must be a boolean")
        end

        unless is_boolean(category["types"]) do
          invalid_snapshot!(category_label, "types must be a boolean")
        end

        if schema_version == 3 do
          require_fields!(category, ["support"], category_label)
          validate_string_field!(category, "support", category_label)
        else
          validate_optional_string_field!(category, "support", category_label)
        end

        category["name"]
      end)

    duplicates = duplicate_values(names)

    if duplicates != [] do
      invalid_snapshot!(label, "category names must be unique: #{inspect(duplicates)}")
    end

    MapSet.new(names)
  end

  defp validate_modules!(modules, schema_version, category_names, label) when is_list(modules) do
    if modules == [], do: invalid_snapshot!(label, "modules must be a non-empty list")

    modules
    |> Enum.with_index()
    |> Enum.map(fn {module, index} ->
      validate_module!(module, schema_version, category_names, "#{label}.modules[#{index}]")
    end)
    |> unique_names!(label, "modules")
  end

  defp validate_modules!(_modules, _schema_version, _category_names, label),
    do: invalid_snapshot!(label, "modules must be a non-empty list")

  defp validate_module!(module, schema_version, category_names, label) when is_map(module) do
    require_fields!(module, @module_required_fields, label)

    if schema_version == 3 do
      require_fields!(module, ["signatures"], label)
    end

    validate_string_field!(module, "module", label)
    validate_string_field!(module, "source", label)
    validate_string_field!(module, "category", label)
    validate_string_field!(module, "kind", label)

    unless MapSet.member?(category_names, module["category"]) do
      invalid_snapshot!(label, "category #{inspect(module["category"])} is not declared")
    end

    unless module["kind"] in ["module", "struct", "behaviour", "protocol"] do
      invalid_snapshot!(label, "kind must be module, struct, behaviour, or protocol")
    end

    validate_export_list!(module["functions"], "functions", label)
    validate_export_list!(module["macros"], "macros", label)
    validate_callbacks!(module["callbacks"], label)
    validate_types!(module["types"], label)
    validate_string_list!(module["struct_fields"], "struct_fields", label)

    if Map.has_key?(module, "signatures") do
      validate_signatures!(module["signatures"], label)
    end

    module["module"]
  end

  defp validate_module!(_module, _schema_version, _category_names, label),
    do: invalid_snapshot!(label, "must be an object")

  defp validate_excluded_modules!(modules, category_names, label) when is_list(modules) do
    modules
    |> Enum.with_index()
    |> Enum.map(fn {module, index} ->
      entry_label = "#{label}.excluded_modules[#{index}]"

      unless is_map(module), do: invalid_snapshot!(entry_label, "must be an object")
      require_fields!(module, ~w(category module source), entry_label)
      validate_string_field!(module, "category", entry_label)
      validate_string_field!(module, "module", entry_label)
      validate_string_field!(module, "source", entry_label)

      unless MapSet.member?(category_names, module["category"]) do
        invalid_snapshot!(entry_label, "category #{inspect(module["category"])} is not declared")
      end

      module["module"]
    end)
    |> unique_names!(label, "excluded_modules")
  end

  defp validate_excluded_modules!(_modules, _category_names, label),
    do: invalid_snapshot!(label, "excluded_modules must be a list")

  defp validate_export_list!(exports, field, label) when is_list(exports) do
    unless Enum.all?(exports, &(is_binary(&1) and Regex.match?(~r/^.+\/[0-9]+$/, &1))) do
      invalid_snapshot!(label, "#{field} must contain export strings in name/arity form")
    end
  end

  defp validate_export_list!(_exports, field, label),
    do: invalid_snapshot!(label, "#{field} must be a list")

  defp validate_callbacks!(callbacks, label) when is_list(callbacks) do
    Enum.with_index(callbacks)
    |> Enum.each(fn {callback, index} ->
      entry_label = "#{label}.callbacks[#{index}]"
      unless is_map(callback), do: invalid_snapshot!(entry_label, "must be an object")
      require_fields!(callback, ~w(name optional), entry_label)
      validate_string_field!(callback, "name", entry_label)

      unless is_boolean(callback["optional"]) do
        invalid_snapshot!(entry_label, "optional must be a boolean")
      end
    end)
  end

  defp validate_callbacks!(_callbacks, label),
    do: invalid_snapshot!(label, "callbacks must be a list")

  defp validate_types!(types, label) when is_list(types) do
    Enum.with_index(types)
    |> Enum.each(fn {type, index} ->
      entry_label = "#{label}.types[#{index}]"
      unless is_map(type), do: invalid_snapshot!(entry_label, "must be an object")
      require_fields!(type, ~w(kind name), entry_label)
      validate_string_field!(type, "kind", entry_label)
      validate_string_field!(type, "name", entry_label)

      unless type["kind"] in ["type", "opaque"] do
        invalid_snapshot!(entry_label, "kind must be type or opaque")
      end
    end)
  end

  defp validate_types!(_types, label), do: invalid_snapshot!(label, "types must be a list")

  defp validate_signatures!(signatures, label) when is_map(signatures) do
    Enum.each(signatures, fn {kind, members} ->
      entry_label = "#{label}.signatures.#{kind}"

      unless is_binary(kind) and kind in @signature_kinds do
        invalid_snapshot!(entry_label, "signature kinds must be callbacks, functions, or types")
      end

      unless is_map(members), do: invalid_snapshot!(entry_label, "must be an object")

      Enum.each(members, fn {member, values} ->
        unless is_binary(member) and is_list(values) and Enum.all?(values, &is_binary/1) do
          invalid_snapshot!(entry_label, "signature members must map strings to string lists")
        end
      end)
    end)
  end

  defp validate_signatures!(_signatures, label),
    do: invalid_snapshot!(label, "signatures must be an object")

  defp validate_string_list!(values, field, label) when is_list(values) do
    unless Enum.all?(values, &is_binary/1),
      do: invalid_snapshot!(label, "#{field} must contain only strings")
  end

  defp validate_string_list!(_values, field, label),
    do: invalid_snapshot!(label, "#{field} must be a list")

  defp validate_optional_string_field!(map, field, label) do
    if Map.has_key?(map, field) and not is_binary(map[field]) do
      invalid_snapshot!(label, "#{field} must be a string when present")
    end
  end

  defp unique_names!(names, label, field) do
    duplicates = duplicate_values(names)

    if duplicates != [],
      do:
        invalid_snapshot!(
          label,
          "#{field} must not contain duplicate module names: #{inspect(duplicates)}"
        )

    names
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp valid_semver?(version) when is_binary(version) do
    Regex.match?(~r/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:[-+].*)?$/, version)
  end

  defp valid_semver?(_version), do: false

  defp invalid_snapshot!(label, reason),
    do: Mix.raise("invalid public API snapshot #{label}: #{reason}")

  defp module_map(manifest), do: Map.new(Map.get(manifest, "modules", []), &{&1["module"], &1})

  defp removed_modules(previous, current) do
    previous
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(current, &1))
    |> Enum.map(&%{"type" => "module_removed", "module" => &1})
  end

  defp added_modules(previous, current) do
    current
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(previous, &1))
    |> Enum.map(&%{"type" => "module_added", "module" => &1})
  end

  defp changed_modules(previous, current) do
    previous
    |> Map.keys()
    |> Enum.filter(&Map.has_key?(current, &1))
    |> Enum.flat_map(fn module -> module_changes(previous[module], current[module]) end)
  end

  defp module_changes(previous, current) do
    module = current["module"]
    changes = []

    changes =
      if previous["category"] != current["category"],
        do: [
          %{
            "type" => "module_tier_changed",
            "module" => module,
            "from" => previous["category"],
            "to" => current["category"]
          }
          | changes
        ],
        else: changes

    changes =
      if previous["source"] != current["source"],
        do: [
          %{
            "type" => "module_source_changed",
            "module" => module,
            "from" => previous["source"],
            "to" => current["source"]
          }
          | changes
        ],
        else: changes

    changes =
      if previous["kind"] != current["kind"],
        do: [
          %{
            "type" => "module_kind_changed",
            "module" => module,
            "from" => previous["kind"],
            "to" => current["kind"]
          }
          | changes
        ],
        else: changes

    changes ++
      member_changes(module, previous, current, "functions") ++
      member_changes(module, previous, current, "macros") ++
      member_changes(module, previous, current, "callbacks") ++
      member_changes(module, previous, current, "types") ++
      member_changes(module, previous, current, "struct_fields") ++
      signature_changes(module, previous, current)
  end

  defp member_changes(module, previous, current, key) do
    old = member_set(previous, key)
    new = member_set(current, key)

    removed =
      old
      |> MapSet.difference(new)
      |> Enum.map(
        &%{
          "type" => "#{String.trim_trailing(key, "s")}_removed",
          "module" => module,
          "member" => &1
        }
      )

    added =
      new
      |> MapSet.difference(old)
      |> Enum.map(
        &%{
          "type" => "#{String.trim_trailing(key, "s")}_added",
          "module" => module,
          "member" => &1
        }
      )

    removed ++ added
  end

  defp signature_changes(module, previous, current) do
    old = Map.get(previous, "signatures", %{})
    new = Map.get(current, "signatures", %{})

    old
    |> Map.keys()
    |> Kernel.++(Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn kind ->
      old_kind = Map.get(old, kind, %{})
      new_kind = Map.get(new, kind, %{})

      old_kind
      |> Map.keys()
      |> Kernel.++(Map.keys(new_kind))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn member ->
        if Map.has_key?(old_kind, member) and Map.has_key?(new_kind, member) and
             old_kind[member] != new_kind[member] do
          [
            %{
              "type" => "signature_changed",
              "module" => module,
              "member" => "#{kind}.#{member}",
              "from" => old_kind[member],
              "to" => new_kind[member]
            }
          ]
        else
          []
        end
      end)
    end)
  end

  defp added_members(previous, current) do
    changed_modules(previous, current)
    |> Enum.filter(&String.ends_with?(&1["type"], "_added"))
  end

  defp breaking_module_changes(previous, current) do
    changed_modules(previous, current)
    |> Enum.reject(&String.ends_with?(&1["type"], "_added"))
  end

  defp member_set(entry, key) do
    entry
    |> Map.get(key, [])
    |> Enum.map(fn
      %{"kind" => kind, "name" => name} -> "#{kind}:#{name}"
      %{"name" => name} -> name
      value -> value
    end)
    |> MapSet.new()
  end

  defp metadata_changes(previous, current) do
    ["schema_version", "app", "package_version", "scope", "categories", "excluded_modules"]
    |> Enum.flat_map(fn key ->
      if Map.get(previous, key) != Map.get(current, key) do
        [
          %{
            "type" => "metadata_changed",
            "field" => key,
            "from" => Map.get(previous, key),
            "to" => Map.get(current, key)
          }
        ]
      else
        []
      end
    end)
  end

  defp sort_changes(changes), do: Enum.sort_by(changes, &Jason.encode!(&1))

  defp parse_version!(version) do
    case Regex.run(
           ~r/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:[-+].*)?$/,
           version,
           capture: :all_but_first
         ) do
      [major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

      _ ->
        Mix.raise("public API diff requires a SemVer package version, got: #{inspect(version)}")
    end
  end

  defp category_definitions(policy) do
    policy["categories"]
    |> Enum.map(fn {name, config} -> Map.put(config, "name", name) end)
    |> Enum.sort_by(& &1["name"])
  end

  defp source_path(module) do
    module.module_info(:compile)
    |> Keyword.fetch!(:source)
    |> List.to_string()
    |> Path.expand()
    |> Path.relative_to(File.cwd!())
  end

  defp ordered_json_term(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested} -> {key, ordered_json_term(nested)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered_json_term(value) when is_list(value), do: Enum.map(value, &ordered_json_term/1)
  defp ordered_json_term(value), do: value

  defp load_application! do
    case Application.load(:imp) do
      :ok ->
        :ok

      {:error, {:already_loaded, :imp}} ->
        :ok

      {:error, reason} ->
        Mix.raise("unable to load :imp application metadata: #{inspect(reason)}")
    end
  end
end
