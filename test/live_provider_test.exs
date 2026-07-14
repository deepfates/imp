defmodule LiveProviderTest do
  use ExUnit.Case

  @tag :live
  test "ReqLLM-backed live provider completes an Imp prediction" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL")

    assert is_binary(api_key) and byte_size(api_key) > 0
    assert is_binary(model) and byte_size(model) > 0

    lm = Imp.req_llm("openai:#{model}", temperature: 0, max_completion_tokens: 20)
    program = Imp.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             Imp.Predict.Predict.call(program, %{
               question: "Reply with exactly this single word and no punctuation: pong"
             })

    answer =
      prediction
      |> Imp.Prediction.get(:answer, "")
      |> to_string()
      |> String.downcase()

    assert String.contains?(answer, "pong")
  end

  @tag :live
  test "ReqLLM-backed live provider completes structured JSON prediction" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL")

    assert is_binary(api_key) and byte_size(api_key) > 0
    assert is_binary(model) and byte_size(model) > 0

    lm = Imp.req_llm("openai:#{model}", temperature: 0, max_completion_tokens: 80)

    program =
      Imp.predict("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, prediction} =
             Imp.Predict.Predict.call(program, %{
               question: "Return only a JSON object. The answer must be pong and score must be 7."
             })

    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7
  end

  @tag :live
  test "ReqLLM-backed live provider accepts native JSON schema response format" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL")

    assert is_binary(api_key) and byte_size(api_key) > 0
    assert is_binary(model) and byte_size(model) > 0

    lm = Imp.req_llm("openai:#{model}", temperature: 0, max_completion_tokens: 80)

    program =
      Imp.predict("question -> answer, score: int",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [native_json_schema: true]
      )

    assert {:ok, prediction} =
             Imp.Predict.Predict.call(program, %{
               question: "Set answer to pong and score to 7."
             })

    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7
  end
end
