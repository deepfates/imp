defmodule LiveProviderTest do
  use ExUnit.Case

  @tag :live
  test "OpenAI-compatible live provider completes a Dachshund prediction" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL") || "gpt-4o-mini"

    assert is_binary(api_key) and byte_size(api_key) > 0

    lm = Dachshund.Clients.OpenAI.new(model, opts: [temperature: 0, max_completion_tokens: 20])
    program = Dachshund.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             Dachshund.Predict.Predict.call(program, %{
               question: "Reply with exactly this single word and no punctuation: pong"
             })

    answer =
      prediction
      |> Dachshund.Prediction.get(:answer, "")
      |> to_string()
      |> String.downcase()

    assert String.contains?(answer, "pong")
  end

  @tag :live
  test "OpenAI-compatible live provider completes structured JSON prediction" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL") || "gpt-4o-mini"

    assert is_binary(api_key) and byte_size(api_key) > 0

    lm = Dachshund.Clients.OpenAI.new(model, opts: [temperature: 0, max_completion_tokens: 80])

    program =
      Dachshund.predict("question -> answer, score: int", lm: lm, adapter: Dachshund.Adapter.JSON)

    assert {:ok, prediction} =
             Dachshund.Predict.Predict.call(program, %{
               question: "Return only a JSON object. The answer must be pong and score must be 7."
             })

    assert Dachshund.Prediction.get(prediction, :answer) == "pong"
    assert Dachshund.Prediction.get(prediction, :score) == 7
  end
end
