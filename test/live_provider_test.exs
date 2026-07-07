defmodule LiveProviderTest do
  use ExUnit.Case

  @tag :live
  test "ReqLLM-backed live provider completes a DSEx prediction" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL")

    assert is_binary(api_key) and byte_size(api_key) > 0
    assert is_binary(model) and byte_size(model) > 0

    lm = DSEx.req_llm("openai:#{model}", temperature: 0, max_completion_tokens: 20)
    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             DSEx.Predict.Predict.call(program, %{
               question: "Reply with exactly this single word and no punctuation: pong"
             })

    answer =
      prediction
      |> DSEx.Prediction.get(:answer, "")
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

    lm = DSEx.req_llm("openai:#{model}", temperature: 0, max_completion_tokens: 80)

    program =
      DSEx.predict("question -> answer, score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, prediction} =
             DSEx.Predict.Predict.call(program, %{
               question: "Return only a JSON object. The answer must be pong and score must be 7."
             })

    assert DSEx.Prediction.get(prediction, :answer) == "pong"
    assert DSEx.Prediction.get(prediction, :score) == 7
  end

  @tag :live
  test "ReqLLM-backed live provider accepts native JSON schema response format" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL")

    assert is_binary(api_key) and byte_size(api_key) > 0
    assert is_binary(model) and byte_size(model) > 0

    lm = DSEx.req_llm("openai:#{model}", temperature: 0, max_completion_tokens: 80)

    program =
      DSEx.predict("question -> answer, score: int",
        lm: lm,
        adapter: DSEx.Adapter.JSON,
        config: [native_json_schema: true]
      )

    assert {:ok, prediction} =
             DSEx.Predict.Predict.call(program, %{
               question: "Set answer to pong and score to 7."
             })

    assert DSEx.Prediction.get(prediction, :answer) == "pong"
    assert DSEx.Prediction.get(prediction, :score) == 7
  end
end
