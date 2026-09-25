defmodule Imp.SavingSecretSafetyTest do
  use ExUnit.Case, async: true

  test "dump redacts secrets from portable program data at every nesting level" do
    secret = "sk-saving-secret-1234567890"
    basic = "Basic " <> Base.encode64("saving-user:saving-pass")
    session = "session=CANARY_SAVING_SESSION_ASSIGNMENT_42b9d"
    image_secret = "sk-saving-image-url-1234567890"
    prose = "Bearer authentication is an authorization mechanism."
    ordinary_url = "https://example.test/public/image.png?version=4"

    demo =
      Imp.example(question: "saved example", answer: "saved answer", api_key: secret)
      |> Imp.with_inputs(:question)

    program =
      Imp.predict("question -> answer",
        demos: [demo],
        config: [max_tokens: 256, provider_options: [authorization: "Bearer abcdefghijklmnop"]],
        metadata: %{
          deployment_secret: secret,
          token_count: 7,
          basic_header: basic,
          cookie_line: session,
          image: %Imp.Adapter.Types.Image{
            url: "https://example.test/private/#{image_secret}",
            data: "aW1hZ2U=",
            mime_type: "image/png"
          },
          prose: prose,
          ordinary_url: ordinary_url
        }
      )

    state = Imp.dump(program)
    encoded = Jason.encode!(state)

    refute encoded =~ secret
    refute encoded =~ "Bearer abcdefghijklmnop"
    refute encoded =~ basic
    refute encoded =~ session
    refute encoded =~ image_secret

    loaded = Imp.load(state)
    assert loaded.metadata.deployment_secret == "[REDACTED]"
    assert loaded.metadata.token_count == 7
    assert loaded.metadata.basic_header == "[REDACTED]"
    assert loaded.metadata.cookie_line == "[REDACTED]"
    assert loaded.metadata.image.url == "[REDACTED]"
    assert loaded.metadata.image.data == "aW1hZ2U="
    assert loaded.metadata.prose == prose
    assert loaded.metadata.ordinary_url == ordinary_url
    assert loaded.config[:max_tokens] == 256
    assert loaded.config[:provider_options] == []
    assert Imp.Example.get(hd(loaded.demos), :api_key) == "[REDACTED]"
  end

  test "file artifacts redact secrets in nested tool data and preserve registry rebinding" do
    secret = "sk-tool-secret-1234567890"
    runner = fn %{"query" => query} -> query end
    registry = Imp.Saving.Registry.new(lookup: runner)

    tool =
      Imp.tool(:lookup, "Use credential #{secret}", runner,
        schema: %{
          query: :string,
          token: :string,
          api_key: :string,
          auth_token: %{type: :string},
          actual_token: %{token: secret, api_key: secret},
          note: "Bearer abcdefghijklmnop"
        }
      )

    program = Imp.react("question -> answer", [tool], max_iters: 0)

    path =
      Path.join(System.tmp_dir!(), "imp-secret-safe-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.save!(program, path, registry: registry)
    artifact = File.read!(path)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    refute artifact =~ secret
    refute artifact =~ "Bearer abcdefghijklmnop"

    loaded = Imp.load!(path, registry: registry)
    assert loaded.tools.lookup.description == "[REDACTED]"
    assert loaded.tools.lookup.schema.note == "[REDACTED]"
    assert loaded.tools.lookup.schema.token == :string
    assert loaded.tools.lookup.schema.api_key == :string
    assert loaded.tools.lookup.schema.auth_token == %{type: :string}

    assert loaded.tools.lookup.schema.actual_token == %{
             token: "[REDACTED]",
             api_key: "[REDACTED]"
           }

    assert Imp.Tool.call(loaded.tools.lookup, %{query: "beam"}) == "beam"

    # Atomic replacement preserves the private mode rather than inheriting an
    # existing destination's broader permissions.
    File.chmod!(path, 0o644)
    assert :ok = Imp.save!(program, path, registry: registry)
    assert {:ok, %File.Stat{mode: replaced_mode}} = File.stat(path)
    assert Bitwise.band(replaced_mode, 0o777) == 0o600
  end

  test "tool closures fail with an actionable registry requirement" do
    tool = Imp.tool(:lookup, "lookup", fn args -> args end)
    program = Imp.react("question -> answer", [tool])

    assert_raise ArgumentError,
                 ~r/ReAct tool lookup is not present in the supplied saving registry/,
                 fn -> Imp.dump(program) end
  end

  test "ReqLLM model identities remain exact while credentials stay redacted" do
    hash = String.duplicate("a", 64)
    other_hash = String.duplicate("b", 64)
    model_path = "/private/tmp/imp-mlx/#{hash}/fused"

    model = %{
      provider: :openai,
      id: model_path,
      model: model_path,
      token: "model-descriptor-secret",
      extra: %{authorization: "Bearer nested-secret"}
    }

    state =
      Imp.predict("question -> answer",
        lm: Imp.req_llm(model, api_key: "runtime-secret")
      )
      |> Imp.dump()

    encoded = Jason.encode!(state)

    assert get_in(state, ["lm", :model, :id]) == model_path
    assert get_in(state, ["lm", :model, :model]) == model_path
    refute Map.has_key?(state["lm"][:model], :token)
    refute Map.has_key?(state["lm"][:model][:extra], :authorization)
    refute encoded =~ "runtime-secret"
    refute encoded =~ "model-descriptor-secret"
    refute encoded =~ "nested-secret"
    refute encoded =~ other_hash

    distinct = put_in(model, [:id], "/private/tmp/imp-mlx/#{other_hash}/fused")

    distinct_state =
      Imp.predict("question -> answer", lm: Imp.req_llm(distinct))
      |> Imp.dump()

    refute get_in(distinct_state, ["lm", :model, :id]) == get_in(state, ["lm", :model, :id])
  end
end
