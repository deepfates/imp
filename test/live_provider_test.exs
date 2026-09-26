defmodule LiveProviderTest do
  use ExUnit.Case

  @tag :live
  test "ReqLLM-backed live provider completes an Imp prediction" do
    lm = Imp.Test.LiveProvider.lm(max_completion_tokens: 20)
    program = Imp.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             Imp.Predict.call(program, %{
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
    lm = Imp.Test.LiveProvider.lm(max_completion_tokens: 80)

    program =
      Imp.predict("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, prediction} =
             Imp.Predict.call(program, %{
               question: "Return only a JSON object. The answer must be pong and score must be 7."
             })

    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7
  end

  @tag :live
  test "ReqLLM-backed live provider accepts native JSON schema response format" do
    lm = Imp.Test.LiveProvider.lm(max_completion_tokens: 80)

    program =
      Imp.predict("question -> answer, score: int",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [native_json_schema: true]
      )

    assert {:ok, prediction} =
             Imp.Predict.call(program, %{
               question: "Set answer to pong and score to 7."
             })

    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7
  end

  # The README's hero example prints its output (#=> "security"). That
  # annotation was aspirational once and wrong in practice (a cold reader
  # caught the old ticket answering "billing" 4/4) — this test makes the
  # front door's displayed result a live-verified claim: exact README
  # program, exact README ticket, exact README model, temp 0.
  @tag :live
  test "the README hero example produces its displayed output" do
    # The README pins "openai:gpt-5.4-mini" verbatim; the same model via the
    # OpenRouter route still verifies the displayed output when no native
    # OpenAI key is provisioned.
    {lm_spec, api_key} =
      case System.get_env("OPENAI_API_KEY") do
        key when key not in [nil, ""] -> {"openai:gpt-5.4-mini", key}
        _missing -> {"openrouter:openai/gpt-5.4-mini", System.fetch_env!("OPENROUTER_API_KEY")}
      end

    lm = Imp.req_llm(lm_spec, api_key: api_key, temperature: 0)

    route =
      "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
      |> Imp.signature("Assign the support ticket to the team that owns it.")
      |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

    {:ok, prediction} =
      Imp.call(route, %{
        ticket:
          "A customer noticed they can open other users' invoices by changing the number in the URL."
      })

    assert Imp.get(prediction, :team) == "security"
  end
end
