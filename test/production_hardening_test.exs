defmodule ProductionHardeningTest do
  use ExUnit.Case

  defmodule FlakyTransport do
    @behaviour DSPy.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      count = Process.get(:flaky_count, 0)
      Process.put(:flaky_count, count + 1)

      if count == 0 do
        {:ok, %{status: 503, headers: [], body: "try again"}}
      else
        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{choices: [%{message: %{content: "Answer: recovered"}}]})
         }}
      end
    end
  end

  test "HTTP LM retries retryable provider failures" do
    Process.delete(:flaky_count)

    lm =
      DSPy.Clients.OpenAI.new("gpt-test",
        api_key: "sk-test",
        transport: FlakyTransport,
        opts: [num_retries: 1, retry_backoff_ms: 0]
      )

    program = DSPy.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = DSPy.Predict.Predict.call(program, %{question: "recover?"})
    assert DSPy.Prediction.get(prediction, :answer) == "recovered"
    assert Process.get(:flaky_count) == 2
  end

  test "saving rejects unsupported program types explicitly" do
    assert_raise ArgumentError, ~r/unsupported saved DSPy program type/, fn ->
      DSPy.Saving.load(%{"type" => "unknown"})
    end
  end

  test "parallel maps preserve per-input success shape under concurrency" do
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}
    program = DSPy.predict("question -> answer", lm: lm)

    results =
      DSPy.Predict.Parallel.map(program, [
        %{question: "a"},
        %{question: "b"},
        %{question: "c"}
      ])

    assert Enum.all?(results, &match?({:ok, %DSPy.Prediction{}}, &1))
  end
end
