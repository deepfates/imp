defmodule ProductionAdapterPersistenceTest do
  use ExUnit.Case

  defmodule SaveTransport do
    @behaviour DSPy.HTTP

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
    signature = DSPy.signature("question: str -> score: int")
    assert [:question] == DSPy.Signature.input_names(signature)

    assert [%{name: :score, type: :integer}] =
             Enum.map(signature.outputs, &Map.take(&1, [:name, :type]))

    assert {:ok, prediction} = DSPy.Adapter.JSON.parse(signature, ~s({"score": "42"}), [])
    assert DSPy.Prediction.get(prediction, :score) == 42
  end

  test "json adapter parses fenced provider json and rejects missing fields" do
    signature = DSPy.signature("question -> answer, confidence: float")

    assert {:ok, prediction} =
             DSPy.Adapter.JSON.parse(
               signature,
               """
               ```json
               {"answer": "Paris", "confidence": "0.95", "ignored": {"nested": true}}
               ```
               """,
               []
             )

    assert DSPy.Prediction.get(prediction, :answer) == "Paris"
    assert DSPy.Prediction.get(prediction, :confidence) == 0.95

    assert {:error, {:missing_output_fields, [:confidence]}} =
             DSPy.Adapter.JSON.parse(signature, ~s({"answer": "Paris"}), [])
  end

  test "save/load preserves adapter and HTTP provider configuration" do
    lm =
      DSPy.Clients.OpenAI.new("gpt-test",
        api_key: "not-persisted",
        base_url: "https://example.invalid/v1",
        transport: SaveTransport,
        opts: [temperature: 0, num_retries: 0]
      )

    program = DSPy.predict("question -> score: int", lm: lm, adapter: DSPy.Adapter.JSON)
    path = Path.join(System.tmp_dir!(), "dspy-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSPy.Saving.save!(program, path)
    loaded = DSPy.Saving.load!(path)
    File.rm(path)

    assert loaded.adapter == DSPy.Adapter.JSON

    assert %DSPy.Clients.HTTPLM{model: "gpt-test", base_url: "https://example.invalid/v1"} =
             loaded.lm

    refute loaded.lm.api_key == "not-persisted"
    assert loaded.config == []
  end
end
