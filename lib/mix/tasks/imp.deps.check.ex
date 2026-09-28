defmodule Mix.Tasks.Imp.Deps.Check do
  @moduledoc """
  Fail when Imp's code names a module from an application Imp does not declare.

  A module that reaches Imp only through another dependency can disappear or
  change version when that dependency changes its own requirements, so every
  application whose modules Imp names must be declared in `mix.exs`.

      mix imp.deps.check

  The task runs in `:test`, where every declared dependency is built, and
  compiles the project first. It collects, for each compiled source file:

    * from each module's debug info (the Erlang abstract code its compiler
      backend returns): remote calls and function captures, struct names in
      patterns and constructions, `@behaviour`, every `Elixir.`-prefixed alias
      anywhere in the code (module attributes read in a function, keyword or
      map values, lists), and the module argument of `apply`, `is_struct` and
      `Code.ensure_loaded?`/`ensure_loaded`/`ensure_compiled`;
    * from Mix's compile manifest: the compile-time, export and runtime
      references Elixir recorded, which include modules used only at compile
      time (`import NimbleParsec`, `require`, a macro that expands to no
      remote call).

  An atom without the `Elixir.` prefix counts only where it is used as a
  module (the shapes above), so `%{mode: :jose}` is data. An Erlang module
  held only as data (`[adapter: :some_erlang_module]` passed to a library that
  calls it) is therefore not seen. A module whose name is built at runtime
  (`String.to_existing_atom/1`, `Module.concat/1` of runtime values) cannot be
  seen either. Typespecs are not read.

  Each module is mapped to its application through the `.app` files in the
  build path and in the Erlang/OTP and Elixir installations. A name in Imp's
  own namespace that no module defines is a registered process name and
  counts as Imp. Any other name that no application defines fails the check,
  since a dependency that is not built would otherwise pass silently.

  A file the Hex package ships may name Imp, an Erlang/OTP or Elixir
  application, or a dependency declared for every environment that Imp
  starts. The exceptions are the dependencies in `@started_on_demand`, which
  are `runtime: false` but which shipped code uses. Other compiled files
  (source-checkout tasks, `bench/`, `test/support/`) may also name
  dependencies declared only for `:dev` or `:test`, or `runtime: false`.
  """

  use Mix.Task

  require Mix.Compilers.Elixir, as: ElixirCompiler

  @shortdoc "Fail when Imp names a module from an undeclared application"

  # runtime: false dependencies whose modules shipped code may call: Imp
  # starts them on the first protocol connection rather than at boot, and a
  # release that uses Imp.MCP or Imp.ACP bundles them in :load mode
  # (docs/production.md, "Releases that use MCP or ACP").
  @started_on_demand [:ex_mcp, :erlexec]

  @ensure_functions [
    :ensure_loaded?,
    :ensure_loaded,
    :ensure_loaded!,
    :ensure_compiled,
    :ensure_compiled!
  ]

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("mix imp.deps.check takes no arguments")

    Mix.Task.run("compile", [])

    config = Mix.Project.config()
    manifest = read_manifest()
    context = context(config)

    source_of = for {source, _refs, modules} <- manifest, m <- modules, into: %{}, do: {m, source}

    compile_path = Mix.Project.compile_path()

    beam_entries =
      for module <- own_modules(compile_path, config[:app]) do
        beam = Path.join(compile_path, "#{module}.beam")
        {source, names} = references(String.to_charlist(beam))
        {Map.get(source_of, module) || source || {:no_source, module}, names}
      end

    manifest_entries = for {source, refs, _modules} <- manifest, do: {source, refs}

    case check(beam_entries ++ manifest_entries, context) do
      :ok ->
        Mix.shell().info("Every application Imp names is declared in mix.exs.")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc false
  # What the check allows, from the project configuration.
  def context(config) do
    {shipped_deps, any_deps} = declared(config[:deps])

    %{
      own: config[:app],
      module_apps: Map.merge(standard_module_apps(), module_apps(Mix.Project.build_path())),
      shipped_deps: shipped_deps,
      any_deps: any_deps,
      shipped?: &MapSet.member?(shipped_sources(config), &1)
    }
  end

  @doc false
  # entries: [{source, names}], where source is a path relative to the
  # project or {:no_source, module} for a module whose file is not known
  # (compiled with ERL_COMPILER_OPTIONS=deterministic and absent from the
  # manifest). A module without a known file is held to the shipped rule.
  def check(entries, context) do
    merged =
      Enum.reduce(entries, %{}, fn {source, names}, acc ->
        Map.update(acc, source, MapSet.new(names), &MapSet.union(&1, MapSet.new(names)))
      end)

    namespace = "Elixir." <> Macro.camelize(to_string(context.own))

    app_by_name =
      for {_source, names} <- merged, name <- names, into: %{} do
        {name, app_of(name, context, namespace)}
      end

    findings =
      for {source, names} <- merged,
          name <- names,
          app = Map.fetch!(app_by_name, name),
          app not in [context.own, :std],
          allowed =
            if(shipped?(source, context), do: context.shipped_deps, else: context.any_deps),
          app not in allowed,
          do: {source, name, app}

    case Enum.sort(findings) do
      [] ->
        :ok

      found ->
        lines =
          Enum.map(found, fn
            {source, name, :unresolved} ->
              "  #{label(source)}: #{inspect(name)} (no built application defines it)"

            {source, name, app} ->
              "  #{label(source)}: #{inspect(name)} (#{app})"
          end)

        {:error,
         """
         Imp names modules from applications mix.exs does not declare for that \
         file (a shipped file needs a dependency declared for every environment \
         and started by Imp):
         #{Enum.join(lines, "\n")}
         """}
    end
  end

  defp shipped?(source, context) when is_binary(source), do: context.shipped?.(source)
  defp shipped?({:no_source, _module}, _context), do: true

  defp label(source) when is_binary(source), do: source
  defp label({:no_source, module}), do: "#{inspect(module)} (no source file recorded)"

  @doc false
  # The source file recorded in a compiled module (nil when it was compiled
  # without one, as ERL_COMPILER_OPTIONS=deterministic does) and the modules
  # its debug info names.
  def references(beam) do
    {:ok, {module, chunks}} = :beam_lib.chunks(beam, [:debug_info, :compile_info])
    source = chunks |> Keyword.fetch!(:compile_info) |> Keyword.get(:source)

    names =
      case Keyword.fetch!(chunks, :debug_info) do
        {:debug_info_v1, backend, data} when data != :none ->
          case backend.debug_info(:erlang_v1, module, data, []) do
            {:ok, forms} ->
              forms |> Enum.flat_map(&form_names/1) |> Enum.uniq() |> List.delete(module)

            {:error, reason} ->
              Mix.raise("cannot read the debug info of #{inspect(module)}: #{inspect(reason)}")
          end

        _none ->
          Mix.raise(
            "#{inspect(module)} was compiled without debug info, so its references cannot be read"
          )
      end

    {source && source |> List.to_string() |> Path.relative_to_cwd(), names}
  end

  defp form_names({:attribute, _line, behaviour, name})
       when behaviour in [:behaviour, :behavior] and is_atom(name),
       do: [name]

  defp form_names({:attribute, _line, _name, _value}), do: []
  defp form_names(form), do: walk(form, [])

  defp walk({:call, _, {:remote, _, {:atom, _, module}, {:atom, _, function}}, args}, acc) do
    acc = [module | named_argument(module, function, args) ++ acc]
    walk(args, acc)
  end

  defp walk({:fun, _, {:function, {:atom, _, module}, _function, _arity}}, acc),
    do: [module | acc]

  defp walk({field, _, {:atom, _, :__struct__}, {:atom, _, module}}, acc)
       when field in [:map_field_exact, :map_field_assoc],
       do: [module | acc]

  # is_struct(value, module) outside a guard: case module of m when is_atom(m).
  defp walk(
         {:case, _, {:atom, _, module},
          [
            {:clause, _, [{:var, _, var}],
             [
               [
                 {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :is_atom}},
                  [{:var, _, var}]}
               ]
             ], _body}
            | _clauses
          ]} = form,
         acc
       ),
       do: walk(Tuple.delete_at(form, 2), [module | acc])

  defp walk({:op, _, :"=:=", left, right}, acc) do
    acc = struct_test(left, right) ++ struct_test(right, left) ++ acc
    walk(right, walk(left, acc))
  end

  defp walk({:atom, _, atom}, acc), do: if(alias?(atom), do: [atom | acc], else: acc)
  defp walk(tuple, acc) when is_tuple(tuple), do: walk(Tuple.to_list(tuple), acc)
  defp walk([head | tail], acc), do: walk(tail, walk(head, acc))
  defp walk(_other, acc), do: acc

  # apply(module, ...), Code.ensure_loaded?(module) and friends.
  defp named_argument(:erlang, :apply, [{:atom, _, module} | _rest]), do: [module]

  defp named_argument(Code, function, [{:atom, _, module} | _rest])
       when function in @ensure_functions,
       do: [module]

  defp named_argument(_module, _function, _args), do: []

  # is_struct(value, module) in a guard: map_get(:__struct__, value) =:= module.
  defp struct_test(
         {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :map_get}},
          [{:atom, _, :__struct__}, _value]},
         {:atom, _, module}
       ),
       do: [module]

  defp struct_test(_left, _right), do: []

  defp alias?(atom), do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  # [{source, references, modules}] from Mix's compile manifest, read with
  # Mix's own reader and record macros (Mix.Compilers.Elixir, not a public
  # API). A change to them fails this task loudly, at compile time or in the
  # matches below, rather than silently reading nothing.
  defp read_manifest do
    path = Path.join(Mix.Project.manifest_path(), "compile.elixir")
    {_modules, sources} = ElixirCompiler.read_manifest(path)

    for {source, record} <- sources do
      fields = ElixirCompiler.source(record)

      refs =
        Keyword.fetch!(fields, :compile_references) ++
          Keyword.fetch!(fields, :export_references) ++
          Keyword.fetch!(fields, :runtime_references)

      {source, refs, Keyword.fetch!(fields, :modules)}
    end
  end

  # Declared dependencies a shipped file may name, and those any compiled
  # file may name.
  defp declared(deps) do
    Enum.reduce(deps, {[], []}, fn dep, {shipped, any} ->
      {app, opts} = name_and_opts(dep)
      every_env? = :prod in (opts |> Keyword.get(:only, [:prod]) |> List.wrap())
      started? = Keyword.get(opts, :runtime, true) or app in @started_on_demand
      shipped = if every_env? and started?, do: [app | shipped], else: shipped
      {shipped, [app | any]}
    end)
  end

  defp name_and_opts({app, opts}) when is_list(opts), do: {app, opts}
  defp name_and_opts({app, _requirement}), do: {app, []}
  defp name_and_opts({app, _requirement, opts}), do: {app, opts}

  defp shipped_sources(config) do
    config
    |> Keyword.fetch!(:package)
    |> Keyword.fetch!(:files)
    |> Enum.filter(&(String.starts_with?(&1, "lib/") and String.ends_with?(&1, ".ex")))
    |> MapSet.new()
  end

  defp module_apps(build_path) do
    for app_file <- Path.wildcard(Path.join(build_path, "lib/*/ebin/*.app")),
        {:ok, [{:application, app, properties}]} = :file.consult(app_file),
        module <- Keyword.get(properties, :modules, []),
        into: %{},
        do: {module, app}
  end

  # Read from the .app file just written: the application spec loaded in
  # this VM can predate the compile.
  defp own_modules(compile_path, own) do
    {:ok, [{:application, ^own, properties}]} =
      :file.consult(Path.join(compile_path, "#{own}.app"))

    Keyword.fetch!(properties, :modules)
  end

  # The application a module belongs to, from the .app files of the build
  # path (dependencies and Imp) and of Erlang/OTP and Elixir (:std);
  # :unresolved when no application lists it.
  # An alias in Imp's own namespace that no module defines is a registered
  # process name (Imp.TaskSupervisor) and belongs to Imp.
  defp app_of(name, context, namespace) do
    case Map.fetch(context.module_apps, name) do
      {:ok, app} ->
        app

      :error ->
        text = Atom.to_string(name)

        if text == namespace or String.starts_with?(text, namespace <> "."),
          do: context.own,
          else: :unresolved
    end
  end

  defp standard_module_apps do
    elixir_lib = :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()
    otp_lib = Path.join(List.to_string(:code.root_dir()), "lib")

    for root <- [otp_lib, elixir_lib],
        app_file <- Path.wildcard(Path.join(root, "*/ebin/*.app")),
        {:ok, [{:application, _app, properties}]} = :file.consult(app_file),
        module <- Keyword.get(properties, :modules, []),
        into: %{},
        do: {module, :std}
  end
end
