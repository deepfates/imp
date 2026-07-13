defmodule AvatarPersistenceTest do
  use ExUnit.Case, async: true

  test "Avatar round-trips portable actor state through named callbacks" do
    runner = fn %{query: query} -> "found #{query}" end
    policy = fn name, _arguments -> name in [:lookup, "lookup"] end
    registry = DSEx.Saving.Registry.new(lookup_runner: runner, avatar_policy: policy)

    avatar =
      DSEx.avatar(
        "question -> answer",
        [
          DSEx.tool(:lookup, "lookup facts Bearer abcdefghijklmnop", runner,
            schema: %{
              api_key: %{type: :string},
              default_token: "Bearer abcdefghijklmnop"
            }
          )
        ],
        lm: DSEx.req_llm("openai:gpt-avatar", api_key: "sk-avatar-secret-123456"),
        max_iters: 4,
        tool_policy: policy,
        metadata: %{
          api_key: "sk-metadata-secret-123456",
          release: "2026-07-13"
        }
      )
      |> DSEx.Predict.Avatar.put_instruction("Use lookup once, then finish.")

    state = DSEx.dump(avatar, registry: registry)
    encoded = Jason.encode!(state)

    assert state["type"] == "avatar"
    assert state["tools"] |> hd() |> Map.fetch!("runner") == "lookup_runner"
    assert state["tool_policy"] == %{"registry_callback" => "avatar_policy"}
    assert state["metadata"]["api_key"] == "[REDACTED]"
    refute encoded =~ "sk-avatar-secret"
    refute encoded =~ "sk-metadata-secret"
    refute encoded =~ "Bearer abcdefghijklmnop"
    refute encoded =~ "#Function<"

    restored = encoded |> Jason.decode!(keys: :strings) |> DSEx.load(registry: registry)

    assert %DSEx.Predict.Avatar{max_iters: 4} = restored
    assert restored.actor.lm == %DSEx.Clients.ReqLLM{model: "openai:gpt-avatar", opts: []}
    assert restored.finisher.lm == %DSEx.Clients.ReqLLM{model: "openai:gpt-avatar", opts: []}
    assert restored.tool_policy == policy
    assert restored.tools.lookup.run == runner
    assert restored.tools.lookup.schema.api_key == %{type: :string}
    assert restored.tools.lookup.schema.default_token == "[REDACTED]"
    assert restored.metadata.api_key == "[REDACTED]"
    assert restored.metadata.release == "2026-07-13"
    assert DSEx.Predict.Avatar.current_instruction(restored) == "Use lookup once, then finish."
  end

  test "Avatar rejects runtime functions outside the callback registry" do
    avatar =
      DSEx.avatar("question -> answer", [],
        metadata: %{runtime_callback: fn -> :not_portable end}
      )

    assert_raise ArgumentError,
                 ~r/Avatar actor metadata must contain only portable JSON data/,
                 fn ->
                   DSEx.dump(avatar)
                 end
  end

  test "Avatar loader validates nested actor and finisher contracts" do
    state = DSEx.avatar("question -> answer", []) |> DSEx.dump()
    unrelated = DSEx.predict("question -> answer") |> DSEx.dump()

    assert_raise ArgumentError, ~r/Avatar actor signature does not match/, fn ->
      state |> Map.put("actor", unrelated) |> DSEx.load()
    end

    assert_raise ArgumentError, ~r/Avatar finisher signature does not match/, fn ->
      state |> Map.put("finisher", unrelated) |> DSEx.load()
    end

    assert_raise ArgumentError, ~r/Avatar max_iters must be a non-negative integer/, fn ->
      state |> Map.put("max_iters", -1) |> DSEx.load()
    end
  end

  test "early Avatar payloads without metadata load with an empty map" do
    restored =
      DSEx.avatar("question -> answer", [])
      |> DSEx.dump()
      |> Map.delete("metadata")
      |> DSEx.load()

    assert restored.metadata == %{}
  end
end
