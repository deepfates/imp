defmodule PredictMultiCompletionUsageTest do
  @moduledoc """
  Regressions for the de-hzcv API-boundary wave (gaps 1/6/9): `n=`
  multi-completion, the per-prediction usage ledger, and per-call LM config.

  The happy paths are pinned by the ported upstream tests
  (test/upstream_exam/predict_test.exs: multi output, multi output2, lm usage,
  lm usage with parallel, predicted outputs piped). This file pins the loud
  failure modes and Imp-specific guarantees around them.
  """

  use ExUnit.Case, async: true

  defp capture_lm(%Imp.Test.FunLM{fun: response_fun}), do: capture_lm(response_fun)

  defp capture_lm(response_fun) do
    test_pid = self()

    Imp.Test.FunLM.new(fn messages, opts ->
      send(test_pid, {:lm_call, messages, opts})
      response_fun.(messages, opts)
    end)
  end

  defp scripted_multi_lm(responses) do
    Imp.Test.FunLM.new(fn _messages, opts ->
      n = Keyword.get(opts, :n, 1)
      {:ok, Enum.take(responses, n)}
    end)
  end

  describe "n= multi-completion loudness" do
    test "an LM that ignores :n and returns a single output is a loud error, not one quiet completion" do
      lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:ok, %{answer: "only one"}} end)
      program = Imp.Predict.new("question -> answer", lm: lm, config: [n: 3])

      assert {:error, {:multi_completion_not_returned, 3, message}} =
               Imp.Predict.call(program, %{question: "q"})

      assert message =~ "n=3"
    end

    test "a parse failure on one of the K completions fails the whole call with the failing index" do
      lm = scripted_multi_lm([%{answer: "good"}, "no field markers here at all"])

      program =
        Imp.Predict.new("question -> answer",
          lm: lm,
          config: [n: 2, json_fallback: false]
        )

      assert {:error,
              %Imp.AdapterParseError{kind: :missing_fields, completion_index: 1, trace: %{}}} =
               Imp.Predict.call(program, %{question: "q"})
    end

    test "an invalid :n is a loud error" do
      lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:ok, %{answer: "x"}} end)
      program = Imp.Predict.new("question -> answer", lm: lm, config: [n: 0])

      assert {:error, {:invalid_multi_completion_count, 0}} =
               Imp.Predict.call(program, %{question: "q"})
    end

    test "n > 1 with unset or near-zero temperature bumps to 0.7; an explicit temperature survives" do
      lm = capture_lm(scripted_multi_lm([%{answer: "a"}, %{answer: "b"}]))
      program = Imp.Predict.new("question -> answer", lm: lm, config: [n: 2])

      assert {:ok, _prediction} = Imp.Predict.call(program, %{question: "q"})
      assert_received {:lm_call, _messages, opts}
      assert opts[:temperature] == 0.7

      hot =
        Imp.Predict.new("question -> answer", lm: lm, config: [n: 2, temperature: 1.0])

      assert {:ok, _prediction} = Imp.Predict.call(hot, %{question: "q"})
      assert_received {:lm_call, _messages, hot_opts}
      assert hot_opts[:temperature] == 1.0

      single =
        Imp.Predict.new("question -> answer",
          lm: capture_lm(fn _messages, _opts -> {:ok, %{answer: "a"}} end)
        )

      assert {:ok, _prediction} = Imp.Predict.call(single, %{question: "q"})
      assert_received {:lm_call, _messages, single_opts}
      refute Keyword.has_key?(single_opts, :temperature)
    end

    test "the req_llm client refuses n > 1 loudly instead of dropping completions" do
      lm = Imp.Clients.ReqLLM.new("openai:gpt-4o-mini")

      assert {:error, {:multi_completion_unsupported, Imp.Clients.ReqLLM, message}} =
               Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hi"}], n: 2)

      assert message =~ "first choice"
    end

    test "Imp.LM.Static invokes the handler once per requested completion" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            %{answer: "answer-#{Agent.get_and_update(agent, &{&1, &1 + 1})}"}
          end
        )

      assert {:ok, [%{answer: "answer-0"}, %{answer: "answer-1"}, %{answer: "answer-2"}]} =
               Imp.LM.Static.generate(lm, [], n: 3)

      assert {:ok, %{answer: "answer-3"}} = Imp.LM.Static.generate(lm, [], [])
    end
  end

  describe "usage ledger" do
    test "get_lm_usage is empty when :track_usage is off" do
      lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:ok, %{answer: "x"}} end)
      program = Imp.Predict.new("question -> answer", lm: lm)

      assert {:ok, prediction} = Imp.Predict.call(program, %{question: "q"})
      assert Imp.Prediction.get_lm_usage(prediction) == %{}
    end

    test "usage entries for the same model merge by summing counters, nested maps included" do
      {result, usage} =
        Imp.Usage.track(fn ->
          :ok =
            Imp.Usage.record("openai/gpt-4o-mini", %{
              total_tokens: 10,
              completion_tokens_details: %{reasoning_tokens: 2}
            })

          :ok =
            Imp.Usage.record("openai/gpt-4o-mini", %{
              total_tokens: 5,
              completion_tokens_details: %{reasoning_tokens: 1}
            })

          :ok = Imp.Usage.record("anthropic/claude", %{total_tokens: 7})
          :done
        end)

      assert result == :done

      assert usage == %{
               "openai/gpt-4o-mini" => %{
                 total_tokens: 15,
                 completion_tokens_details: %{reasoning_tokens: 3}
               },
               "anthropic/claude" => %{total_tokens: 7}
             }
    end

    test "recording without an active tracker is a no-op" do
      assert :ok = Imp.Usage.record("openai/gpt-4o-mini", %{total_tokens: 10})
      refute Imp.Usage.tracking?()
    end
  end

  describe "per-call config (call/3)" do
    test "call-time config reaches the LM without mutating the program" do
      lm = capture_lm(fn _messages, _opts -> {:ok, %{answer: "x"}} end)
      program = Imp.Predict.new("question -> answer", lm: lm, config: [temperature: 0.3])

      assert {:ok, _prediction} =
               Imp.Predict.call(program, %{question: "q"}, temperature: 0.9)

      assert_received {:lm_call, _messages, override_opts}
      assert override_opts[:temperature] == 0.9

      # The program itself is untouched: a plain call/2 uses the stored config.
      assert program.config == [temperature: 0.3]
      assert {:ok, _prediction} = Imp.Predict.call(program, %{question: "q"})
      assert_received {:lm_call, _messages, stored_opts}
      assert stored_opts[:temperature] == 0.3
    end

    test "non-keyword per-call config raises" do
      lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:ok, %{answer: "x"}} end)
      program = Imp.Predict.new("question -> answer", lm: lm)

      assert_raise ArgumentError, ~r/per-call config as a keyword list/, fn ->
        Imp.Predict.call(program, %{question: "q"}, %{temperature: 0.9})
      end
    end
  end
end
