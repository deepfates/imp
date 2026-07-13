defmodule DSEx.Optimizer.GEPA.ConfidenceFrontierTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Candidate, ConfidenceAdapter, Evaluation, Frontier}

  defmodule MultiComponentProgram do
    defstruct []

    def optimizer_predictors(_program) do
      predictor = DSEx.predict("input -> category")
      [first: predictor, second: predictor]
    end

    def update_optimizer_predictor(program, _name, _update), do: program
  end

  defmodule OpenAIChatFixture do
    def generate_text(model, messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      wrong? =
        Enum.any?(messages, fn message ->
          Enum.any?(message.content, fn part ->
            is_binary(part.text) and String.contains?(part.text, "Return the wrong label")
          end)
        end)

      {label, raw_confidence} = if wrong?, do: {"Drinks", 0.95}, else: {"Food", 0.40}
      content = Jason.encode!(%{category: label})

      send(test_pid, {:confidence_request, opts})

      {:ok,
       %ReqLLM.Response{
         id: "chatcmpl_gepa_fixture",
         model: model.provider_model_id || model.id,
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(content),
         object: %{"category" => label},
         usage: %{input_tokens: 20, output_tokens: 5, total_tokens: 25},
         finish_reason: :stop,
         provider_meta: %{
           "api_type" => "chat_completions",
           :logprobs => [
             %{
               "token" => content,
               "logprob" => :math.log(raw_confidence),
               "top_logprobs" => [
                 %{"token" => label, "logprob" => :math.log(raw_confidence)}
               ]
             }
           ]
         }
       }}
    end
  end

  test "confidence objectives flow through ProgramAdapter into the GEPA frontier" do
    lm =
      DSEx.Clients.ReqLLM.new(%{provider: :openai, id: "gpt-fixture"},
        req_module: OpenAIChatFixture,
        test_pid: self()
      )

    program =
      DSEx.predict("input -> category",
        lm: lm,
        adapter: DSEx.Adapter.JSON,
        config: [native_json_schema: true]
      )

    adapter =
      ConfidenceAdapter.new(program,
        field: :category,
        expected_field: :answer,
        enum: ["Food", "Drinks"]
      )

    seed = Candidate.from_program(program)
    correct_candidate = Map.put(seed, :main, "Return the correct label")
    wrong_candidate = Map.put(seed, :main, "Return the wrong label")
    batch = [DSEx.example(input: "lunch", answer: "Food") |> DSEx.with_inputs(:input)]

    correct = Evaluation.evaluate(adapter, batch, correct_candidate, capture_traces: true)
    wrong = Evaluation.evaluate(adapter, batch, wrong_candidate, capture_traces: true)

    assert [%{accuracy: 1.0, raw_confidence: correct_confidence}] = correct.objective_scores
    assert_in_delta correct_confidence, 0.40, 1.0e-12

    assert [%{accuracy: wrong_accuracy, raw_confidence: wrong_confidence}] =
             wrong.objective_scores

    assert wrong_accuracy == 0.0
    assert_in_delta wrong_confidence, 0.95, 1.0e-12

    assert Frontier.mapping([correct: correct, wrong: wrong], :objective) == %{
             {:objective, :accuracy} => MapSet.new([:correct]),
             {:objective, :raw_confidence} => MapSet.new([:wrong])
           }

    assert_receive {:confidence_request, opts}
    provider_options = Keyword.fetch!(opts, :provider_options)
    assert Keyword.fetch!(provider_options, :openai_logprobs)
    assert Keyword.fetch!(provider_options, :openai_top_logprobs) == 5

    assert %LLMDB.Model{provider: :openai, extra: extra} =
             adapter.program_adapter.program.lm.model

    assert get_in(extra, [Access.key(:wire, %{}), :protocol]) == "openai_chat"
  end

  test "confidence adapter rejects programs with more than one component" do
    program = %MultiComponentProgram{}

    assert_raise ArgumentError, ~r/requires exactly one optimizable component, got: 2/, fn ->
      ConfidenceAdapter.new(program, field: :category, enum: ["Food", "Drinks"])
    end
  end

  test "confidence adapter rejects unsupported LM transports before evaluation" do
    program = DSEx.predict("input -> category", lm: DSEx.LM.Static)

    assert_raise ArgumentError, ~r/requires an explicit DSEx.Clients.ReqLLM OpenAI model/, fn ->
      ConfidenceAdapter.new(program, field: :category, enum: ["Food", "Drinks"])
    end
  end
end
