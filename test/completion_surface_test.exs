defmodule CompletionSurfaceTest do
  use ExUnit.Case

  defmodule Transport do
    @behaviour DSPy.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      send(self(), {:http_post, url, headers, Jason.decode!(body)})

      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{choices: [%{message: %{content: "Answer: shipped"}}]})
       }}
    end
  end

  setup do
    DSPy.configure(lm: nil, adapter: DSPy.Adapter.Chat, retriever: nil)
    :ok
  end

  test "openai-compatible provider clients build verifiable HTTP contracts" do
    lm = DSPy.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: Transport)

    assert {:ok, "Answer: shipped"} =
             DSPy.LM.generate(lm, [%{role: :user, content: "hello"}], temperature: 0)

    assert_received {:http_post, "https://api.openai.com/v1/chat/completions", headers, payload}
    assert {"authorization", "Bearer sk-test"} in headers
    assert payload["model"] == "gpt-test"
    assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    assert payload["temperature"] == 0
  end

  test "program of thought evaluates arithmetic in a safe sandbox" do
    lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2 + 1"} end]
    }

    program = DSPy.Predict.ProgramOfThought.new("x -> answer", lm: lm)

    assert {:ok, prediction} = DSPy.Predict.ProgramOfThought.call(program, %{x: 3})
    assert DSPy.Prediction.get(prediction, :answer) == 7
    assert {:error, {:unsafe_ast, _}} = DSPy.Sandbox.eval("System.cmd(\"rm\", [\"-rf\", \"/\"])")
  end

  test "streaming exposes predictions as an enumerable" do
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]}
    program = DSPy.predict("question -> answer", lm: lm)

    assert DSPy.Streaming.collect(program, %{question: "runtime?"}) == "beam"
    assert Enum.take(DSPy.Streaming.stream(program, %{question: "runtime?"}), 2) == ["b", "e"]
  end

  test "dataset loaders produce examples with declared inputs" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dspy-elixir-dataset-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, ~s({"question":"2+2?","answer":"4"}\n{"question":"3+3?","answer":"6"}\n))

    examples = DSPy.Datasets.gsm8k(path)
    assert length(examples) == 2
    assert DSPy.Example.to_map(DSPy.Example.inputs(hd(examples))) == %{question: "2+2?"}

    File.rm(path)
  end

  test "advanced optimizers return executable compiled programs" do
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSPy.predict("question -> answer", lm: lm)

    trainset = [
      DSPy.example(question: "2+2?", answer: "4") |> DSPy.Example.with_inputs(:question),
      DSPy.example(question: "square root of 16?", answer: "4")
      |> DSPy.Example.with_inputs(:question)
    ]

    devset = [
      DSPy.example(question: "2 plus 2?", answer: "4") |> DSPy.Example.with_inputs(:question)
    ]

    metric = DSPy.Metrics.exact_match(:answer)

    compiled =
      [
        DSPy.Teleprompt.COPRO.new(metric, breadth: 3, depth: 1),
        DSPy.Teleprompt.MIPROv2.new(metric, trials: 3, demos_per_candidate: 1),
        DSPy.Teleprompt.SIMBA.new(metric, steps: 2, demos_per_step: 1),
        DSPy.Teleprompt.GEPA.new(metric, generations: 2),
        DSPy.Teleprompt.SignatureOptimizer.new(metric)
      ]
      |> Enum.map(fn optimizer ->
        optimizer.__struct__.compile(optimizer, program, trainset, devset)
      end)

    assert Enum.all?(compiled, fn candidate ->
             {:ok, prediction} = DSPy.Predict.Predict.call(candidate, %{question: "2+2?"})
             DSPy.Prediction.get(prediction, :answer) == "4"
           end)
  end

  test "finetuning and GRPO create provider-neutral training jobs" do
    lm = DSPy.Clients.Local.new("tiny", transport: Transport)
    program = DSPy.predict("question -> answer", lm: lm)
    metric = DSPy.Metrics.exact_match(:answer)

    trainset = [
      DSPy.example(question: "2+2?", answer: "4") |> DSPy.Example.with_inputs(:question)
    ]

    result =
      DSPy.Teleprompt.BootstrapFinetune.new(metric)
      |> DSPy.Teleprompt.BootstrapFinetune.compile(program, trainset)

    assert %DSPy.Clients.TrainingJob{status: :succeeded, result_model: "tiny:finetuned"} =
             result.job

    reward = fn example -> if DSPy.Example.get(example, :answer) == "4", do: 1.0, else: 0.0 end

    assert {:ok, %DSPy.Clients.TrainingJob{status: :succeeded, training_data: [%{reward: 1.0}]}} =
             DSPy.Teleprompt.GRPO.new(reward) |> DSPy.Teleprompt.GRPO.compile(program, trainset)
  end

  test "save/load, embeddings, and compatibility adapters work" do
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> ~s({"answer":"ok"}) end]}
    program = DSPy.predict("question -> answer", lm: lm, adapter: DSPy.Adapter.BAML)

    path =
      Path.join(
        System.tmp_dir!(),
        "dspy-elixir-program-#{System.unique_integer([:positive])}.json"
      )

    assert {:ok, prediction} = DSPy.Predict.Predict.call(program, %{question: "ship?"})
    assert DSPy.Prediction.get(prediction, :answer) == "ok"

    assert :ok = DSPy.Saving.save!(program, path)
    assert %DSPy.Predict.Predict{} = DSPy.Saving.load!(path)
    File.rm(path)

    assert {:ok, [vector]} =
             DSPy.Embeddings.embed(DSPy.Embeddings.BagOfWords, ["hello hello beam"], dims: 8)

    assert length(vector) == 8

    messages = DSPy.Adapter.TwoStep.format(DSPy.signature("q -> a"), %{q: "x"}, [])
    assert Enum.any?(messages, &String.contains?(&1.content, "plan"))
  end
end
