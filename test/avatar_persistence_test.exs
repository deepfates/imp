defmodule AvatarPersistenceTest do
  use ExUnit.Case, async: true

  test "Avatar round-trips portable actor state through named callbacks" do
    runner = fn %{"query" => query} -> "found #{query}" end
    policy = fn name, _arguments -> name in [:lookup, "lookup"] end
    registry = Imp.Saving.Registry.new(lookup_runner: runner, avatar_policy: policy)

    avatar =
      Imp.avatar(
        "question -> answer",
        [
          Imp.tool(:lookup, "lookup facts Bearer abcdefghijklmnop", runner,
            schema: %{
              api_key: %{type: :string},
              default_token: "Bearer abcdefghijklmnop"
            }
          )
        ],
        lm: Imp.req_llm("openai:gpt-avatar", api_key: "sk-avatar-secret-123456"),
        max_iters: 4,
        tool_timeout_ms: 1_234,
        tool_policy: policy,
        metadata: %{
          api_key: "sk-metadata-secret-123456",
          release: "2026-07-13"
        }
      )
      |> Imp.Predict.Avatar.put_instruction("Use lookup once, then finish.")

    state = Imp.dump(avatar, registry: registry)
    encoded = Jason.encode!(state)

    assert state["type"] == "avatar"
    assert state["tools"] |> hd() |> Map.fetch!("runner") == "lookup_runner"
    assert state["tool_policy"] == %{"registry_callback" => "avatar_policy"}
    assert state["tool_timeout_ms"] == 1_234
    assert state["metadata"]["__imp_type__"] == "map"

    assert state["metadata"]
           |> Imp.Optimizer.Report.decode_term()
           |> Map.fetch!(:api_key) == "[REDACTED]"

    refute encoded =~ "sk-avatar-secret"
    refute encoded =~ "sk-metadata-secret"
    refute encoded =~ "Bearer abcdefghijklmnop"
    refute encoded =~ "#Function<"

    restored = encoded |> Jason.decode!(keys: :strings) |> Imp.load(registry: registry)

    assert %Imp.Predict.Avatar{max_iters: 4, tool_timeout_ms: 1_234} = restored
    assert restored.actor.lm == %Imp.Clients.ReqLLM{model: "openai:gpt-avatar", opts: []}
    assert restored.finisher.lm == %Imp.Clients.ReqLLM{model: "openai:gpt-avatar", opts: []}
    assert restored.tool_policy == policy
    assert restored.tools.lookup.run == runner
    assert restored.tools.lookup.description == "[REDACTED]"
    assert restored.tools.lookup.schema.api_key == %{type: :string}
    assert restored.tools.lookup.schema.default_token == "[REDACTED]"
    assert restored.metadata.api_key == "[REDACTED]"
    assert restored.metadata.release == "2026-07-13"
    assert Imp.Predict.Avatar.current_instruction(restored) == "Use lookup once, then finish."
  end

  test "Avatar rejects runtime functions outside the callback registry" do
    avatar =
      Imp.avatar("question -> answer", [], metadata: %{runtime_callback: fn -> :not_portable end})

    assert_raise ArgumentError,
                 ~r/Avatar actor metadata must contain only portable JSON data/,
                 fn ->
                   Imp.dump(avatar)
                 end
  end

  test "Avatar loader validates nested actor and finisher contracts" do
    state = Imp.avatar("question -> answer", []) |> Imp.dump()
    unrelated = Imp.predict("question -> answer") |> Imp.dump()

    assert_raise ArgumentError, ~r/Avatar actor signature does not match/, fn ->
      state |> Map.put("actor", unrelated) |> Imp.load()
    end

    assert_raise ArgumentError, ~r/Avatar finisher signature does not match/, fn ->
      state |> Map.put("finisher", unrelated) |> Imp.load()
    end

    assert_raise ArgumentError, ~r/Avatar max_iters must be a non-negative integer/, fn ->
      state |> Map.put("max_iters", -1) |> Imp.load()
    end

    assert_raise ArgumentError, ~r/Avatar tool_timeout_ms must be a non-negative integer/, fn ->
      state |> Map.put("tool_timeout_ms", -1) |> Imp.load()
    end
  end

  test "early Avatar payloads without metadata load with an empty map" do
    restored =
      Imp.avatar("question -> answer", [])
      |> Imp.dump()
      |> Map.delete("metadata")
      |> Imp.load()

    assert restored.metadata == %{}
  end

  test "early Avatar payloads without a tool timeout load with the bounded default" do
    restored =
      Imp.avatar("question -> answer", [])
      |> Imp.dump()
      |> Map.delete("tool_timeout_ms")
      |> Imp.load()

    assert restored.tool_timeout_ms == 30_000
  end
end
