defmodule Mix.Tasks.Imp.Package.CleanRoom do
  @moduledoc """
  Prove package deployment and persistence from isolated, offline consumer VMs.

  By default the task builds an unpacked Hex package, creates a clean consumer,
  writes a callback-bearing artifact in one VM, and loads it in a second VM with
  a separately constructed callback registry. The loader explicitly supplies a
  fresh credential-bearing LM, executes the program, and verifies that a
  modified artifact fails its checksum. It then compiles the deployment example
  shipped in the package as a release and probes it in a third VM.

      mix imp.package.clean_room
      mix imp.package.clean_room --package tmp/package-check
      mix imp.package.clean_room --lock mix.lock
      mix imp.package.clean_room --skip-release --output tmp/persistence-proof

  Dependency resolution is forced offline with `HEX_OFFLINE=1` and uses the
  source checkout's `mix.lock` by default. Run `mix deps.get` in that checkout
  first so every locked Hex dependency is present in the local cache. Use
  `--lock` to supply a different lockfile. `--package` must name an unpacked
  package directory.
  """

  use Mix.Task

  @shortdoc "Prove clean-room package persistence and deployment"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [package: :string, lock: :string, output: :string, skip_release: :boolean]
      )

    if argv != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(argv ++ invalid)}")
    end

    root = File.cwd!()
    output = opts |> Keyword.get(:output, "tmp/package-clean-room") |> Path.expand(root)
    validate_output!(output, opts[:package], root)
    File.rm_rf!(output)
    File.mkdir_p!(output)

    package_dir = prepare_package!(opts[:package], output, root)
    lockfile = prepare_lock!(opts[:lock], root)
    prove_persistence!(package_dir, lockfile, output)

    unless opts[:skip_release] do
      prove_release!(package_dir, lockfile, output)
    end

    Mix.shell().info("clean-room package proof passed: #{Path.relative_to(output, root)}")
  end

  defp validate_output!(output, package, root) do
    if output in [root, Path.expand("/")] do
      Mix.raise("--output must not be the project or filesystem root")
    end

    if package do
      package_dir = Path.expand(package, root)

      if output_contains_package?(output, package_dir) do
        Mix.raise("--output must not contain the supplied package directory")
      end
    end
  end

  @doc false
  def output_contains_package?(output, package_dir) do
    output = Path.expand(output)
    package_dir = Path.expand(package_dir)

    package_dir == output or String.starts_with?(package_dir, output <> "/")
  end

  defp prepare_package!(nil, output, root) do
    package_dir = Path.join(output, "package")
    run!("mix", ["hex.build", "--unpack", "--output", package_dir], root, [])
    package_dir
  end

  defp prepare_package!(path, _output, root) do
    package_dir = Path.expand(path, root)

    unless File.regular?(Path.join(package_dir, "mix.exs")) do
      Mix.raise("--package must point to an unpacked package directory: #{package_dir}")
    end

    package_dir
  end

  defp prepare_lock!(path, root) do
    lockfile = Path.expand(path || "mix.lock", root)

    unless File.regular?(lockfile) do
      Mix.raise("offline clean-room proof requires a lockfile: #{lockfile}")
    end

    lockfile
  end

  defp prove_persistence!(package_dir, lockfile, output) do
    consumer_dir = Path.join(output, "consumer")
    artifact = Path.join(output, "program.json")
    tampered = Path.join(output, "program.tampered.json")

    write_consumer!(consumer_dir, package_dir, lockfile)
    offline_mix!(consumer_dir, ["deps.get"])
    offline_mix!(consumer_dir, ["compile", "--warnings-as-errors"])

    env = [
      {"IMP_CLEAN_ROOM_ARTIFACT", artifact},
      {"IMP_CLEAN_ROOM_TAMPERED", tampered}
    ]

    offline_mix!(consumer_dir, ["run", "--no-compile", "--no-deps-check", "writer.exs"], env)

    offline_mix!(
      consumer_dir,
      ["run", "--no-compile", "--no-deps-check", "loader.exs"],
      [{"IMP_CLEAN_ROOM_API_KEY", "loader-runtime-secret"} | env]
    )

    artifact
  end

  defp prove_release!(package_dir, lockfile, output) do
    source = Path.join(package_dir, "examples/deployment")

    unless File.regular?(Path.join(source, "mix.exs")) do
      Mix.raise("package does not contain examples/deployment")
    end

    deployment_dir = Path.join(output, "deployment")
    release_dir = Path.join(output, "release")
    artifact = Path.join(output, "release-program.json")
    File.cp_r!(source, deployment_dir)
    File.cp!(lockfile, Path.join(deployment_dir, "mix.lock"))

    offline_mix!(
      Path.join(output, "consumer"),
      ["run", "--no-compile", "--no-deps-check", "release_writer.exs"],
      [{"IMP_CLEAN_ROOM_RELEASE_ARTIFACT", artifact}]
    )

    env = [{"IMP_PATH", package_dir}]
    offline_mix!(deployment_dir, ["deps.get"], env)
    offline_mix!(deployment_dir, ["release", "--path", release_dir], env)

    release_env = [
      {"IMP_ARTIFACT_PATH", artifact},
      {"IMP_STATIC_ANSWER", "release-runtime"}
    ]

    expression = """
    {:ok, _} = Application.ensure_all_started(:imp_deployment)
    {:ok, prediction} = ImpDeployment.ProgramServer.call(%{question: "release probe"})

    unless Imp.get(prediction, :answer) == "release-runtime" do
      raise "unexpected release prediction: \#{inspect(prediction)}"
    end

    IO.puts("clean-room release probe passed")
    """

    executable = Path.join(release_dir, "bin/imp_deployment")
    run!(executable, ["eval", expression], deployment_dir, release_env)
  end

  defp write_consumer!(consumer_dir, package_dir, lockfile) do
    File.mkdir_p!(Path.join(consumer_dir, "lib"))
    File.cp!(lockfile, Path.join(consumer_dir, "mix.lock"))

    File.write!(
      Path.join(consumer_dir, "mix.exs"),
      """
      defmodule ImpCleanRoom.MixProject do
        use Mix.Project

        def project do
          [
            app: :imp_clean_room,
            version: "0.1.0",
            elixir: "~> 1.19",
            deps: [{:imp, path: #{inspect(package_dir)}}]
          ]
        end

        def application, do: [extra_applications: [:logger]]
      end
      """
    )

    File.write!(
      Path.join(consumer_dir, "lib/runtime_lm.ex"),
      """
      defmodule ImpCleanRoom.RuntimeLM do
        @behaviour Imp.LM

        @impl true
        def generate(_messages, opts) do
          case Keyword.fetch!(opts, :api_key) do
            "loader-runtime-secret" -> {:ok, %{answer: Keyword.fetch!(opts, :answer)}}
            other -> raise "runtime credential was not rebound: \#{inspect(other)}"
          end
        end
      end
      """
    )

    File.write!(Path.join(consumer_dir, "writer.exs"), writer_script())
    File.write!(Path.join(consumer_dir, "loader.exs"), loader_script())
    File.write!(Path.join(consumer_dir, "release_writer.exs"), release_writer_script())
  end

  defp writer_script do
    """
    artifact = System.fetch_env!("IMP_CLEAN_ROOM_ARTIFACT")
    metric = fn _example, prediction -> Imp.get(prediction, :answer, "") != "" end
    registry = Imp.Saving.Registry.new(quality_metric: metric)

    persisted_lm =
      Imp.req_llm("openai:package-writer", api_key: "writer-build-secret", temperature: 0)

    program =
      Imp.predict("question -> answer", lm: persisted_lm)
      |> Imp.Predict.BestOfN.new(metric, n: 1)

    :ok = Imp.save!(program, artifact, registry: registry)
    body = File.read!(artifact)

    unless body =~ "payload_sha256" and body =~ "quality_metric" do
      raise "artifact is missing its checksum or registered callback"
    end

    if body =~ "writer-build-secret" do
      raise "writer credentials leaked into the portable artifact"
    end

    IO.puts("clean-room writer VM passed")
    """
  end

  defp loader_script do
    """
    artifact = System.fetch_env!("IMP_CLEAN_ROOM_ARTIFACT")
    tampered = System.fetch_env!("IMP_CLEAN_ROOM_TAMPERED")

    loader_metric = fn _example, prediction ->
      Imp.get(prediction, :answer) == "loader-runtime"
    end

    loader_registry = Imp.Saving.Registry.new(quality_metric: loader_metric)
    loaded = Imp.load!(artifact, registry: loader_registry)

    runtime_lm = %{
      module: ImpCleanRoom.RuntimeLM,
      opts: [
        api_key: System.fetch_env!("IMP_CLEAN_ROOM_API_KEY"),
        answer: "loader-runtime"
      ]
    }

    rebound = Imp.with_lm(loaded, runtime_lm)
    {:ok, prediction} = Imp.call(rebound, %{question: "cross-VM persistence?"})

    unless Imp.get(prediction, :answer) == "loader-runtime" do
      raise "loaded program did not execute with the rebound runtime LM"
    end

    envelope = artifact |> File.read!() |> Jason.decode!()
    payload = Map.update!(envelope["payload"], "n", &(&1 + 1))
    File.write!(tampered, Jason.encode!(%{envelope | "payload" => payload}))

    try do
      Imp.load!(tampered, registry: loader_registry)
      raise "tampered artifact was accepted"
    rescue
      error in ArgumentError ->
        unless Exception.message(error) =~ "checksum mismatch" do
          reraise error, __STACKTRACE__
        end
    end

    IO.puts("clean-room loader VM and tamper rejection passed")
    """
  end

  defp release_writer_script do
    """
    artifact = System.fetch_env!("IMP_CLEAN_ROOM_RELEASE_ARTIFACT")
    metric = fn _example, prediction -> Imp.get(prediction, :answer, "") != "" end
    registry = Imp.Saving.Registry.new(quality_metric: metric)

    program =
      Imp.predict("question -> answer")
      |> Imp.Predict.BestOfN.new(metric, n: 1)

    :ok = Imp.save!(program, artifact, registry: registry)
    IO.puts("clean-room dynamic release artifact written")
    """
  end

  defp offline_mix!(directory, args, extra_env \\ []) do
    env = [{"HEX_OFFLINE", "1"}, {"MIX_ENV", "prod"} | extra_env]
    run!("mix", args, directory, env)
  end

  defp run!(command, args, directory, env) do
    {output, status} =
      System.cmd(command, args,
        cd: directory,
        env: env,
        stderr_to_stdout: true
      )

    Mix.shell().info(output)

    if status != 0 do
      Mix.raise("command failed (#{status}): #{command} #{Enum.join(args, " ")}")
    end
  end
end
