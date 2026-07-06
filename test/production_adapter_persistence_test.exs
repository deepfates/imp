defmodule ProductionAdapterPersistenceTest do
  use ExUnit.Case

  defmodule SaveTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{choices: [%{message: %{content: ~s({"score": 7})}}]})
       }}
    end
  end

  test "typed signatures coerce adapter outputs" do
    signature = DSEx.signature("question: string -> score: int")
    assert [:question] == DSEx.Signature.input_names(signature)

    assert [%{name: :score, type: :integer}] =
             Enum.map(signature.outputs, &Map.take(&1, [:name, :type]))

    assert {:ok, prediction} = DSEx.Adapter.JSON.parse(signature, ~s({"score": "42"}), [])
    assert DSEx.Prediction.get(prediction, :score) == 42
  end

  test "json adapter parses fenced provider json and rejects missing fields" do
    signature = DSEx.signature("question -> answer, confidence: float")

    assert {:ok, prediction} =
             DSEx.Adapter.JSON.parse(
               signature,
               """
               ```json
               {"answer": "Paris", "confidence": "0.95", "ignored": {"nested": true}}
               ```
               """,
               []
             )

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert DSEx.Prediction.get(prediction, :confidence) == 0.95

    assert {:error, {:missing_output_fields, [:confidence]}} =
             DSEx.Adapter.JSON.parse(signature, ~s({"answer": "Paris"}), [])
  end

  test "chat adapter parses delimited output and falls back to JSON" do
    signature = DSEx.signature("question -> answer: string, score: number")

    assert {:ok, delimited} =
             DSEx.Adapter.Chat.parse(
               signature,
               """
               [[ ## answer ## ]]
               Paris
               [[ ## score ## ]]
               1.0
               """,
               []
             )

    assert DSEx.Prediction.get(delimited, :answer) == "Paris"
    assert DSEx.Prediction.get(delimited, :score) == 1.0

    assert {:ok, json} =
             DSEx.Adapter.Chat.parse(signature, ~s({"answer":"Paris","score":1.0}), [])

    assert DSEx.Prediction.get(json, :score) == 1.0
  end

  test "JSON adapter supplies provider response format options and retry feedback" do
    signature = DSEx.signature("question -> answer: string")

    assert [response_format: %{type: "json_object"}] = DSEx.Adapter.JSON.lm_opts(signature, [])

    assert [response_format: %{type: "json_schema", json_schema: %{schema: schema}}] =
             DSEx.Adapter.JSON.lm_opts(signature, native_json_schema: true)

    assert schema["required"] == ["answer"]
  end

  test "save/load preserves adapter and HTTP provider configuration" do
    lm =
      DSEx.Clients.OpenAI.new("gpt-test",
        api_key: "not-persisted",
        base_url: "https://example.invalid/v1",
        transport: SaveTransport,
        opts: [temperature: 0, num_retries: 0]
      )

    program = DSEx.predict("question -> score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    path =
      Path.join(System.tmp_dir!(), "DSEx-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(program, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    assert loaded.adapter == DSEx.Adapter.JSON

    assert %DSEx.Clients.HTTPLM{model: "gpt-test", base_url: "https://example.invalid/v1"} =
             loaded.lm

    refute loaded.lm.api_key == "not-persisted"
    assert loaded.config == []
  end

  test "save/load preserves dynamic LM rebinding for settings-based programs" do
    program = DSEx.predict("question -> answer")

    path =
      Path.join(System.tmp_dir!(), "DSEx-dynamic-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(program, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "settings-ok"} end]
    }

    assert {:ok, prediction} =
             DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
               DSEx.call(loaded, %{question: "works?"})
             end)

    assert DSEx.Prediction.get(prediction, :answer) == "settings-ok"
  end
end
