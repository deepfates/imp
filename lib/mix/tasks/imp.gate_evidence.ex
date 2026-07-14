defmodule Mix.Tasks.Imp.GateEvidence do
  @moduledoc """
  Run a source-checkout gate and write a dashboard-consumable evidence artifact.

      mix imp.gate_evidence --gate product_package --mix-task package.check

  This task is intentionally outside the packaged Imp API. It exists so release
  gates such as package, Livebook, protocol, and paid live checks can become
  durable dashboard evidence instead of prose claims.
  """

  use Mix.Task

  @shortdoc "Run a source-checkout gate and write release evidence"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          gate: :string,
          mix_task: :string,
          out: :string,
          env_file: :string,
          env: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    gate = Keyword.get(opts, :gate) || Mix.raise("--gate is required")
    mix_task = Keyword.get(opts, :mix_task) || Mix.raise("--mix-task is required")
    out_dir = Keyword.get(opts, :out, "tmp/gate-evidence")
    env = env(opts)
    env_files = Keyword.get_values(opts, :env_file)

    File.mkdir_p!(out_dir)

    {duration_us, {output, status}} =
      :timer.tc(fn ->
        System.cmd(mix_executable!(), [mix_task],
          cd: File.cwd!(),
          env: Imp.BenchmarkEnv.values_from_files!(env_files) ++ env,
          stderr_to_stdout: true
        )
      end)

    artifact = artifact(gate, mix_task, env, env_files, output, status, duration_us)
    out_path = Path.join(out_dir, "gate-evidence-#{slug(gate)}-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(artifact, pretty: true) <> "\n")

    Mix.shell().info("gate evidence: #{out_path}")
    Mix.shell().info("#{gate}: #{if(status == 0, do: "passing", else: "failing")}")

    if status != 0 do
      Mix.raise("#{gate} gate failed; inspect #{out_path}")
    end
  end

  defp artifact(gate, mix_task, env, env_files, output, status, duration_us) do
    %{
      "schema_version" => 1,
      "runner" => "imp-gate-evidence",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "gate" => gate,
      "command" => %{
        "executable" => mix_executable!(),
        "args" => [mix_task],
        "env_files" => env_files,
        "env" => Enum.map(env, fn {key, _value} -> key end)
      },
      "summary" => %{
        "mix_task" => mix_task,
        "passing" => status == 0,
        "exit_status" => status,
        "duration_ms" => System.convert_time_unit(duration_us, :microsecond, :millisecond)
      },
      "output_tail" => output_tail(output)
    }
  end

  defp env(opts) do
    opts
    |> Keyword.get_values(:env)
    |> Enum.map(fn assignment ->
      case String.split(assignment, "=", parts: 2) do
        [key, value] when key != "" -> {key, value}
        _ -> Mix.raise("invalid --env assignment #{inspect(assignment)}; expected KEY=value")
      end
    end)
  end

  defp output_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp mix_executable! do
    System.find_executable("mix") || Mix.raise("mix executable not found")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim("-")
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
    |> String.replace("Z", "Z")
  end
end
