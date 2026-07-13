defmodule AvatarDeploymentPersistenceTest do
  use ExUnit.Case, async: true

  test "checksummed Avatar artifact loads in a fresh task and executes rebound callbacks" do
    runner = fn %{country: "France"} -> "Paris" end
    policy = fn name, _arguments -> name in [:lookup, "lookup"] end
    registry = DSEx.Saving.Registry.new(lookup_runner: runner, avatar_policy: policy)
    path = temp_path("avatar-deployment")
    on_exit(fn -> File.rm(path) end)

    avatar =
      DSEx.avatar(
        "question -> answer",
        [DSEx.tool(:lookup, "look up a capital", runner)],
        lm: DSEx.req_llm("openai:gpt-avatar", api_key: "sk-deploy-secret-123456"),
        max_iters: 2,
        tool_policy: policy
      )

    assert :ok = DSEx.save!(avatar, path, registry: registry)

    loaded =
      Task.async(fn -> DSEx.load!(path, registry: registry) end)
      |> Task.await()
      |> DSEx.Predict.Avatar.with_lm(deployment_lm())

    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["artifact_type"] == "dsex_program_artifact"
    assert artifact["payload_sha256"] =~ ~r/^sha256:[a-f0-9]{64}$/
    refute File.read!(path) =~ "sk-deploy-secret"

    assert {:ok, prediction} = DSEx.call(loaded, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris"
    assert DSEx.get(prediction, :termination_reason) == :finish

    assert [%DSEx.Predict.Avatar.ActionOutput{tool_output: "Paris"}] =
             DSEx.get(prediction, :actions)
  end

  test "compiled Avatar optimizer output preserves its deployment report" do
    metric = fn _example, prediction -> DSEx.get(prediction, :answer) == "Paris" end

    student =
      DSEx.avatar("question -> answer", [],
        lm: finish_lm(),
        metadata: %{deployment: "candidate"}
      )

    trainset = [
      DSEx.example(question: "Capital?", answer: "Paris") |> DSEx.with_inputs(:question)
    ]

    compiled =
      DSEx.Optimizer.Avatar.new(metric, max_iters: 0)
      |> DSEx.Optimizer.Avatar.compile(student, trainset)

    path = temp_path("compiled-avatar")
    on_exit(fn -> File.rm(path) end)

    assert :ok = DSEx.save!(compiled, path)

    loaded =
      Task.async(fn -> DSEx.load!(path) end)
      |> Task.await()
      |> DSEx.Predict.Avatar.with_lm(finish_lm())

    report = DSEx.Optimizer.Report.fetch(loaded)
    assert report.optimizer == :avatar
    assert report.best_score == 1.0
    assert report.candidate_count == 1
    assert report.metadata.stop_reason == :max_iters
    assert loaded.metadata.deployment == "candidate"

    assert {:ok, prediction} = DSEx.call(loaded, %{question: "Capital?"})
    assert DSEx.get(prediction, :answer) == "Paris"
  end

  defp deployment_lm do
    static_lm(fn prompt ->
      cond do
        prompt =~ "Do not request another tool." -> %{answer: "Paris"}
        prompt =~ "tool_output: \"Paris\"" -> finish_action()
        true -> %{action: %{tool_name: "lookup", tool_input_query: %{country: "France"}}}
      end
    end)
  end

  defp finish_lm do
    static_lm(fn prompt ->
      if prompt =~ "Do not request another tool.",
        do: %{answer: "Paris"},
        else: finish_action()
    end)
  end

  defp static_lm(handler) do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          messages |> Enum.map_join("\n", & &1.content) |> handler.()
        end
      ]
    }
  end

  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}.json")
  end
end
