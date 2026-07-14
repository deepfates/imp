defmodule AvatarDeploymentPersistenceTest do
  use ExUnit.Case, async: true

  test "checksummed Avatar artifact loads in a fresh task and executes rebound callbacks" do
    runner = fn %{country: "France"} -> "Paris" end
    policy = fn name, _arguments -> name in [:lookup, "lookup"] end
    registry = Imp.Saving.Registry.new(lookup_runner: runner, avatar_policy: policy)
    path = temp_path("avatar-deployment")
    on_exit(fn -> File.rm(path) end)

    avatar =
      Imp.avatar(
        "question -> answer",
        [Imp.tool(:lookup, "look up a capital", runner)],
        lm: Imp.req_llm("openai:gpt-avatar", api_key: "sk-deploy-secret-123456"),
        max_iters: 2,
        tool_policy: policy
      )

    assert :ok = Imp.save!(avatar, path, registry: registry)

    loaded =
      Task.async(fn -> Imp.load!(path, registry: registry) end)
      |> Task.await()
      |> Imp.Predict.Avatar.with_lm(deployment_lm())

    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["artifact_type"] == "imp_program_artifact"
    assert artifact["payload_sha256"] =~ ~r/^sha256:[a-f0-9]{64}$/
    refute File.read!(path) =~ "sk-deploy-secret"

    assert {:ok, prediction} = Imp.call(loaded, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :finish

    assert [%Imp.Predict.Avatar.ActionOutput{tool_output: "Paris"}] =
             Imp.get(prediction, :actions)
  end

  test "compiled Avatar optimizer output preserves its deployment report" do
    metric = fn _example, prediction -> Imp.get(prediction, :answer) == "Paris" end

    student =
      Imp.avatar("question -> answer", [],
        lm: finish_lm(),
        metadata: %{deployment: "candidate"}
      )

    trainset = [
      Imp.example(question: "Capital?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    compiled =
      Imp.Optimizer.Avatar.new(metric, max_iters: 0)
      |> Imp.Optimizer.Avatar.compile(student, trainset)

    path = temp_path("compiled-avatar")
    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.save!(compiled, path)

    loaded =
      Task.async(fn -> Imp.load!(path) end)
      |> Task.await()
      |> Imp.Predict.Avatar.with_lm(finish_lm())

    report = Imp.Optimizer.Report.fetch(loaded)
    assert report.optimizer == :avatar
    assert report.best_score == 1.0
    assert report.candidate_count == 1
    assert report.metadata.stop_reason == :max_iters
    assert loaded.metadata.deployment == "candidate"

    assert {:ok, prediction} = Imp.call(loaded, %{question: "Capital?"})
    assert Imp.get(prediction, :answer) == "Paris"
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
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          messages |> Enum.map_join("\n", & &1.content) |> handler.()
        end
      ]
    }
  end

  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}.json")
  end
end
