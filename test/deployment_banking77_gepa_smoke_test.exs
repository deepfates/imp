defmodule DeploymentBanking77GEPASmokeTest do
  use ExUnit.Case, async: false

  @example Path.expand("../examples/deployment", __DIR__)
  @config Path.join(@example, "banking77_gepa_smoke.json")
  @script Path.join(@example, "banking77_gepa_smoke.exs")

  test "bounded ordinary smoke contract is internally consistent without credentials or network" do
    config = @config |> File.read!() |> Jason.decode!()
    execution = config["execution"]
    calls = execution["call_ceilings"]
    usd = execution["reservation_usd"]

    assert config["status"] == "proposed_unrun"
    assert config["seed"] == 0
    assert config["dataset"]["splits"] == %{"train" => 72, "selection" => 8, "test" => 40}
    assert calls["task_total"] == 240 + 80 + 8
    assert calls["optimizer_total"] == 2
    assert calls["transport_total"] == 330
    assert_in_delta usd["new_maximum"], 328 * 0.007104 + 2 * 0.08064, 1.0e-12
    assert_in_delta usd["aggregate_worst_case"], 7.59315275 + 2.491392, 1.0e-12
    assert execution["cache"] == false
    assert execution["retry"] == false
    assert execution["max_retries"] == 0
    assert execution["fallbacks"] == false
    assert execution["data_collection"] == "deny"

    env = [
      {"IMP_PATH", Path.expand("..", __DIR__)},
      {"IMP_BANKING77_SMOKE_VALIDATE_ONLY", "1"},
      {"OPENROUTER_API_KEY", nil}
    ]

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-start", Path.basename(@script)],
               cd: @example,
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "contract is internally consistent"
  end

  test "ordinary script uses the public experiment and deployment lifecycle" do
    source = File.read!(@script)

    assert source =~ "Imp.Experiment.check"
    assert source =~ "Result.write!"
    assert source =~ "Artifact.write!"
    assert source =~ "ProgramServer.reload_parameters"
    assert source =~ "Task.await_many"
    assert source =~ "IMP_BANKING77_SMOKE_FRESH"
    assert source =~ "allow_fallbacks: false"
    assert source =~ "data_collection: \"deny\""
    assert source =~ "req_http_options: [retry: false, max_retries: 0]"
  end
end
