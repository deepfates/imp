defmodule Mix.Tasks.Imp.Deps.Check do
  @moduledoc """
  Fail when Imp's code names a module from an application Imp does not declare.

  A module that reaches Imp only through another dependency can disappear or
  change version when that dependency changes its own requirements, so every
  application whose modules Imp names must be declared in `mix.exs`.

      mix imp.deps.check

  The task compiles the project and reads each compiled Imp module's BEAM
  file: the modules it calls (the imports chunk) and the module names among
  its literal atoms (the atoms chunk, which holds struct patterns such as
  `%Finch.Error{}` and module lists in guards). Each module is mapped to its
  application through the `.app` files in the build path, or to Erlang/OTP or
  Elixir by where it is loaded from.

  A file the Hex package ships may name Imp, an Erlang/OTP or Elixir
  application, or a dependency declared for every environment. Other compiled
  files (source-checkout tasks, `bench/`, `test/support/`) may also name
  dependencies declared only for `:dev` or `:test`. Typespecs and test scripts
  are not read.
  """

  use Mix.Task

  @shortdoc "Fail when Imp names a module from an undeclared application"

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("mix imp.deps.check takes no arguments")

    Mix.Task.run("compile", [])

    config = Mix.Project.config()
    own = config[:app]
    module_apps = module_apps(Mix.Project.build_path())
    {every_env, any_env} = declared(config[:deps])
    shipped = shipped_sources(config)

    references = Enum.map(own_modules(own), &references/1)

    app_by_name =
      for {_source, names} <- references,
          name <- names,
          uniq: true,
          into: %{},
          do: {name, app_of(name, module_apps)}

    undeclared =
      for {source, names} <- references,
          name <- names,
          app = Map.get(app_by_name, name),
          app not in [nil, own, :std],
          allowed = if(source in shipped, do: every_env, else: any_env),
          app not in allowed,
          uniq: true,
          do: {source, name, app}

    case Enum.sort(undeclared) do
      [] ->
        Mix.shell().info("Every application Imp names is declared in mix.exs.")

      found ->
        lines =
          Enum.map(found, fn {source, name, app} ->
            "  #{source}: #{inspect(name)} (#{app})"
          end)

        Mix.raise("""
        Imp names modules from applications mix.exs does not declare \
        (for a shipped file, declared for every environment):
        #{Enum.join(lines, "\n")}
        """)
    end
  end

  # Declared dependencies available in every environment, and those
  # available in any environment.
  defp declared(deps) do
    Enum.reduce(deps, {[], []}, fn dep, {every_env, any_env} ->
      {app, opts} = name_and_opts(dep)
      only = opts |> Keyword.get(:only, [:prod]) |> List.wrap()
      every_env = if :prod in only, do: [app | every_env], else: every_env
      {every_env, [app | any_env]}
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

  defp own_modules(own) do
    _ = Application.load(own)
    {:ok, modules} = :application.get_key(own, :modules)
    modules
  end

  defp references(module) do
    beam = :code.which(module)

    {:ok, {^module, [atoms: atoms, imports: imports, compile_info: info]}} =
      :beam_lib.chunks(beam, [:atoms, :imports, :compile_info])

    source = info |> Keyword.fetch!(:source) |> List.to_string() |> Path.relative_to_cwd()
    called = for {callee, _function, _arity} <- imports, do: callee
    named = for {_index, atom} <- atoms, atom != module, do: atom

    {source, Enum.uniq(called ++ named)}
  end

  # The application a module belongs to: a built dependency or Imp itself
  # from its .app file, :std for Erlang/OTP and Elixir, nil for an atom that
  # names no module.
  defp app_of(name, module_apps) do
    case Map.fetch(module_apps, name) do
      {:ok, app} -> app
      :error -> standard_or_nil(name)
    end
  end

  defp standard_or_nil(name) do
    case :code.which(name) do
      :preloaded ->
        :std

      path when is_list(path) ->
        if String.starts_with?(List.to_string(path), standard_roots()), do: :std

      _not_a_module ->
        nil
    end
  end

  defp standard_roots do
    [
      List.to_string(:code.root_dir()),
      :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()
    ]
  end
end
