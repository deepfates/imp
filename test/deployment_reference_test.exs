defmodule DeploymentReferenceTest do
  use ExUnit.Case, async: false

  @example_root Path.expand("../examples/deployment", __DIR__)

  setup_all do
    Code.require_file(Path.join(@example_root, "lib/dsex_deployment/callbacks.ex"))
    Code.require_file(Path.join(@example_root, "lib/dsex_deployment/program_server.ex"))
    :ok
  end

  test "reference OTP server loads a checksummed registry-backed artifact and serves calls" do
    path =
      Path.join(System.tmp_dir!(), "dsex-deployment-#{System.unique_integer([:positive])}.json")

    previous_path = System.get_env("DSEX_ARTIFACT_PATH")
    previous_answer = System.get_env("DSEX_STATIC_ANSWER")

    on_exit(fn ->
      File.rm(path)
      restore_env("DSEX_ARTIFACT_PATH", previous_path)
      restore_env("DSEX_STATIC_ANSWER", previous_answer)
    end)

    metric = fn _example, prediction -> DSEx.get(prediction, :answer, "") != "" end
    registry = DSEx.Saving.Registry.new(quality_metric: metric)

    program =
      DSEx.predict("question -> answer")
      |> DSEx.Predict.BestOfN.new(metric, n: 2)

    assert :ok = DSEx.save!(program, path, registry: registry)
    System.put_env("DSEX_ARTIFACT_PATH", path)
    System.put_env("DSEX_STATIC_ANSWER", "Paris")

    start_supervised!(DSExDeployment.ProgramServer)

    assert {:ok, prediction} =
             apply(DSExDeployment.ProgramServer, :call, [%{question: "Capital?"}])

    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "reference project declares both published and source-checkout dependency modes" do
    mix_file = File.read!(Path.join(@example_root, "mix.exs"))
    readme = File.read!(Path.join(@example_root, "README.md"))

    assert mix_file =~ ~s({:dsex, "~> 0.1"})
    assert mix_file =~ "DSEX_PATH"
    assert readme =~ "supervised startup"
    assert readme =~ "DSEX_MODEL"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
