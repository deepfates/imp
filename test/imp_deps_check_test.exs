defmodule Mix.Tasks.Imp.Deps.CheckTest do
  # Compiles probe modules with a global compiler tracer.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Imp.Deps.Check

  # Collects the modules the compiler resolves while compiling a probe, as
  # Mix records them in its manifest for a project file.
  defmodule Tracer do
    @moduledoc false
    @events [
      :import,
      :require,
      :imported_macro,
      :remote_macro,
      :imported_function,
      :remote_function,
      :struct_expansion,
      :alias_reference
    ]

    def trace(event, _env) when elem(event, 0) in @events do
      Agent.update(__MODULE__, &MapSet.put(&1, elem(event, 2)))
    end

    def trace(_event, _env), do: :ok
  end

  # The project's declared dependencies, with every probe checked as a file
  # the package ships unless a test says otherwise.
  setup_all do
    context = Check.context(Mix.Project.config())
    {:ok, context: %{context | shipped?: fn _source -> true end}}
  end

  describe "a shipped file fails on each way of naming an undeclared module" do
    @shapes [
      runtime_false_dependency: "def f(conn), do: Plug.Conn.get_req_header(conn, \"x\")",
      struct_construction: "def f, do: %LLMDB.Model{provider: :openai, id: \"m\"}",
      struct_pattern: "def f(%LLMDB.Model{} = model), do: model",
      struct_named_by_erlang_atom: "def f(%{__struct__: :jose} = value), do: value",
      attribute_list: "@mods [Zoi]\n  def f, do: @mods",
      keyword_value: "def f, do: [adapter: NimblePool]",
      map_value: "def f, do: %{adapter: NimblePool}",
      behaviour: "@behaviour NimblePool\n  def init_worker(state), do: {:ok, state, state}",
      erlang_remote_call: "def f, do: :jose.json_module()",
      function_capture: "def f, do: &:jose.json_module/0",
      apply: "def f, do: apply(:jose, :json_module, [])",
      is_struct: "def f(value), do: is_struct(value, :jose)",
      ensure_loaded: "def f, do: Code.ensure_loaded?(:jose)",
      unresolved_module: "def f, do: [NoSuchLibrary.Module]"
    ]

    # Each of these is found in the module's debug info alone.
    for {shape, body} <- @shapes do
      test "#{shape}", %{context: context} do
        assert {:error, message} = check_probe(unquote(body), context, :debug_info)
        assert message =~ "probe.ex"
      end
    end

    # A macro leaves nothing in the compiled module; the compiler's
    # references, which Mix keeps in its manifest, name it.
    test "compile_time_import", %{context: context} do
      body = "import NimbleParsec\n  defparsec :digits, ascii_string([?0..?9], min: 1)"
      assert :ok = check_probe(body, context, :debug_info)
      assert {:error, message} = check_probe(body, context, :compiler)
      assert message =~ "NimbleParsec (nimble_parsec)"
    end
  end

  test "an Erlang module name used only as data is not a module reference", %{context: context} do
    assert :ok = check_probe("def f, do: %{mode: :jose}", context)
  end

  test "a source-checkout file may name dev and test dependencies", %{context: context} do
    body = "def f, do: Mox.__info__(:module)\n  def g(conn), do: Plug.Conn.halt(conn)"

    assert {:error, _message} = check_probe(body, context)
    assert :ok = check_probe(body, %{context | shipped?: fn _source -> false end})
  end

  @tag :tmp_dir
  test "a module compiled without a source path is read and held to the shipped rule",
       %{tmp_dir: tmp_dir, context: context} do
    # A deterministic build records no source path in the module; this
    # compiles the probe in a VM started with that option, as a build would.
    beam = Path.join(tmp_dir, "Elixir.ImpDepsCheckDeterministicProbe.beam")

    script = """
    [{_module, beam}] =
      Code.compile_string(
        "defmodule ImpDepsCheckDeterministicProbe do\\n  def f, do: Mox.__info__(:module)\\nend",
        "probe.ex"
      )

    File.write!(#{inspect(beam)}, beam)
    """

    {_output, 0} =
      System.cmd("elixir", ["-e", script],
        env: [{"ERL_COMPILER_OPTIONS", "deterministic"}],
        stderr_to_stdout: true
      )

    assert {nil, names} = Check.references(String.to_charlist(beam))
    assert Mox in names

    source_checkout = %{context | shipped?: fn _source -> false end}
    assert :ok = Check.check([{"bench/probe.ex", names}], source_checkout)

    assert {:error, message} =
             Check.check([{{:no_source, ImpDepsCheckDeterministicProbe}, names}], source_checkout)

    assert message =~ "ImpDepsCheckDeterministicProbe (no source file recorded): Mox (mox)"
  end

  defp check_probe(body, context, via \\ :both) do
    {{source, names}, compile_references} = compile_probe(body)

    entries =
      case via do
        :debug_info -> [{source, names}]
        :compiler -> [{source, MapSet.to_list(compile_references)}]
        :both -> [{source, names}, {source, MapSet.to_list(compile_references)}]
      end

    Check.check(entries, context)
  end

  defp compile_probe(body) do
    module = :"Elixir.ImpDepsCheckProbe#{System.unique_integer([:positive])}"
    source = "defmodule #{inspect(module)} do\n  #{body}\nend\n"

    {:ok, _agent} = Agent.start_link(fn -> MapSet.new() end, name: Tracer)
    tracers = Code.get_compiler_option(:tracers)
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:tracers, [Tracer | tracers])
    # The test environment compiles strings without debug info; a project
    # build keeps it.
    Code.put_compiler_option(:debug_info, true)

    try do
      {[{^module, beam}], _warnings} =
        with_io(:stderr, fn -> Code.compile_string(source, "probe.ex") end)

      references = Check.references(beam)
      :code.purge(module)
      :code.delete(module)
      {references, Agent.get(Tracer, & &1)}
    after
      Code.put_compiler_option(:tracers, tracers)
      Code.put_compiler_option(:debug_info, debug_info)
      Agent.stop(Tracer)
    end
  end
end
