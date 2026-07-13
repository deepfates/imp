defmodule DSEx.SavingSecretSafetyTest do
  use ExUnit.Case, async: true

  test "dump redacts secrets from portable program data at every nesting level" do
    secret = "sk-saving-secret-1234567890"

    demo =
      DSEx.example(question: "saved example", answer: "saved answer", api_key: secret)
      |> DSEx.with_inputs(:question)

    program =
      DSEx.predict("question -> answer",
        demos: [demo],
        config: [max_tokens: 256, provider_options: [authorization: "Bearer abcdefghijklmnop"]],
        metadata: %{deployment_secret: secret, token_count: 7}
      )

    state = DSEx.dump(program)
    encoded = Jason.encode!(state)

    refute encoded =~ secret
    refute encoded =~ "Bearer abcdefghijklmnop"

    loaded = DSEx.load(state)
    assert loaded.metadata.deployment_secret == "[REDACTED]"
    assert loaded.metadata.token_count == 7
    assert loaded.config[:max_tokens] == 256
    assert {"authorization", "[REDACTED]"} in loaded.config[:provider_options]
    assert DSEx.Example.get(hd(loaded.demos), :api_key) == "[REDACTED]"
  end

  test "file artifacts redact secrets in nested tool data and preserve registry rebinding" do
    secret = "sk-tool-secret-1234567890"
    runner = fn %{query: query} -> query end
    registry = DSEx.Saving.Registry.new(lookup: runner)

    tool =
      DSEx.tool(:lookup, "Use credential #{secret}", runner,
        schema: %{query: :string, token: :string, note: "Bearer abcdefghijklmnop"}
      )

    program = DSEx.react("question -> answer", [tool], max_iters: 0)

    path =
      Path.join(System.tmp_dir!(), "dsex-secret-safe-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    assert :ok = DSEx.save!(program, path, registry: registry)
    artifact = File.read!(path)

    refute artifact =~ secret
    refute artifact =~ "Bearer abcdefghijklmnop"

    loaded = DSEx.load!(path, registry: registry)
    assert loaded.tools.lookup.description == "[REDACTED]"
    assert loaded.tools.lookup.schema.note == "[REDACTED]"
    assert loaded.tools.lookup.schema.token == :string
    assert DSEx.Tool.call(loaded.tools.lookup, %{query: "beam"}) == "beam"
  end

  test "tool closures fail with an actionable registry requirement" do
    tool = DSEx.tool(:lookup, "lookup", fn args -> args end)
    program = DSEx.react("question -> answer", [tool])

    assert_raise ArgumentError,
                 ~r/ReAct tool lookup is not present in the supplied saving registry/,
                 fn -> DSEx.dump(program) end
  end
end
