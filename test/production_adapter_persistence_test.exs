defmodule ProductionAdapterPersistenceTest do
  use ExUnit.Case

  defmodule SaveTransport do
    @behaviour Dachshund.HTTP

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
    signature = Dachshund.signature("question: str -> score: int")
    assert [:question] == Dachshund.Signature.input_names(signature)

    assert [%{name: :score, type: :integer}] =
             Enum.map(signature.outputs, &Map.take(&1, [:name, :type]))

    assert {:ok, prediction} = Dachshund.Adapter.JSON.parse(signature, ~s({"score": "42"}), [])
    assert Dachshund.Prediction.get(prediction, :score) == 42
  end

  test "json adapter parses fenced provider json and rejects missing fields" do
    signature = Dachshund.signature("question -> answer, confidence: float")

    assert {:ok, prediction} =
             Dachshund.Adapter.JSON.parse(
               signature,
               """
               ```json
               {"answer": "Paris", "confidence": "0.95", "ignored": {"nested": true}}
               ```
               """,
               []
             )

    assert Dachshund.Prediction.get(prediction, :answer) == "Paris"
    assert Dachshund.Prediction.get(prediction, :confidence) == 0.95

    assert {:error, {:missing_output_fields, [:confidence]}} =
             Dachshund.Adapter.JSON.parse(signature, ~s({"answer": "Paris"}), [])
  end

  test "save/load preserves adapter and HTTP provider configuration" do
    lm =
      Dachshund.Clients.OpenAI.new("gpt-test",
        api_key: "not-persisted",
        base_url: "https://example.invalid/v1",
        transport: SaveTransport,
        opts: [temperature: 0, num_retries: 0]
      )

    program = Dachshund.predict("question -> score: int", lm: lm, adapter: Dachshund.Adapter.JSON)

    path =
      Path.join(System.tmp_dir!(), "Dachshund-save-#{System.unique_integer([:positive])}.json")

    assert :ok = Dachshund.Saving.save!(program, path)
    loaded = Dachshund.Saving.load!(path)
    File.rm(path)

    assert loaded.adapter == Dachshund.Adapter.JSON

    assert %Dachshund.Clients.HTTPLM{model: "gpt-test", base_url: "https://example.invalid/v1"} =
             loaded.lm

    refute loaded.lm.api_key == "not-persisted"
    assert loaded.config == []
  end
end
