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

  test "loading saved HTTP LM does not rebind ambient provider credentials" do
    previous = System.get_env("OPENAI_API_KEY")
    Process.put(:previous_openai_api_key, previous)
    System.put_env("OPENAI_API_KEY", "sk-should-not-bind")

    state = %{
      "type" => "predict",
      "signature" => DSPy.Signature.dump(DSPy.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.DSPy.Adapter.Chat",
      "lm" => %{
        "provider" => "openai",
        "model" => "gpt-test",
        "base_url" => "https://evil.example",
        "path" => "/chat/completions",
        "opts" => []
      }
    }

    program = DSPy.Saving.load(state)
    assert %DSPy.Clients.HTTPLM{api_key: nil, base_url: "https://evil.example"} = program.lm
  after
    previous = Process.get(:previous_openai_api_key)

    if previous do
      System.put_env("OPENAI_API_KEY", previous)
    else
      System.delete_env("OPENAI_API_KEY")
    end

    Process.delete(:previous_openai_api_key)
  end

  test "examples and predictions do not intern arbitrary external keys" do
    external_key = "external_key_#{System.unique_integer([:positive])}"

    example = DSPy.Example.new(%{external_key => "kept"})
    prediction = DSPy.Prediction.new(%{external_key => "kept"})

    assert DSPy.Example.to_map(example) == %{external_key => "kept"}
    assert DSPy.Example.get(example, external_key) == "kept"
    assert DSPy.Prediction.to_map(prediction) == %{external_key => "kept"}
    assert DSPy.Prediction.get(prediction, external_key) == "kept"

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
  end

  test "optimize-anything report loading keeps unknown external metadata keys as strings" do
    external_key = "report_key_#{System.unique_integer([:positive])}"

    report =
      %{
        "type" => "optimize_anything_report",
        "best" => nil,
        "baseline" => nil,
        "candidates" => [],
        "errors" => [],
        "metadata" => %{external_key => "kept", "seed" => 1, "artifact_kind" => "prompt"}
      }
      |> DSPy.Optimize.Anything.Report.from_map()

    assert report.metadata[external_key] == "kept"
    assert report.metadata.seed == 1
    assert report.metadata.artifact_kind == :prompt
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
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
