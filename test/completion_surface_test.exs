defmodule CompletionSurfaceTest do
  use ExUnit.Case

  defmodule Transport do
    @behaviour DSEx.HTTP

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
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "openai-compatible provider clients build verifiable HTTP contracts" do
    lm = DSEx.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: Transport)

    assert {:ok, "Answer: shipped"} =
             DSEx.LM.generate(lm, [%{role: :user, content: "hello"}], temperature: 0)

    assert_received {:http_post, "https://api.openai.com/v1/chat/completions", headers, payload}
    assert {"authorization", "Bearer sk-test"} in headers
    assert payload["model"] == "gpt-test"
    assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    assert payload["temperature"] == 0
  end

  test "program of thought evaluates arithmetic in a safe sandbox" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2 + 1"} end]
    }

    program = DSEx.Predict.ProgramOfThought.new("x -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ProgramOfThought.call(program, %{x: 3})
    assert DSEx.Prediction.get(prediction, :answer) == 7

    assert {:error, {:unsafe_ast, _}} =
             DSEx.Sandbox.eval("System.cmd(\"rm\", [\"-rf\", \"/\"])")
  end

  test "streaming exposes predictions as an enumerable" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert DSEx.Streaming.collect(program, %{question: "runtime?"}) == "beam"

    assert Enum.take(DSEx.Streaming.stream(program, %{question: "runtime?"}), 2) == [
             "b",
             "e"
           ]
  end

  test "dataset loaders produce examples with declared inputs" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-dataset-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, ~s({"question":"2+2?","answer":"4"}\n{"question":"3+3?","answer":"6"}\n))

    examples = DSEx.Datasets.gsm8k(path)
    assert length(examples) == 2
    assert DSEx.Example.to_map(DSEx.Example.inputs(hd(examples))) == %{question: "2+2?"}

    File.rm(path)
  end

  test "advanced optimizers return executable compiled programs" do
    lm = %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.Example.with_inputs(:question),
      DSEx.example(question: "square root of 16?", answer: "4")
      |> DSEx.Example.with_inputs(:question)
    ]

    devset = [
      DSEx.example(question: "2 plus 2?", answer: "4")
      |> DSEx.Example.with_inputs(:question)
    ]

    metric = DSEx.Metrics.exact_match(:answer)

    compiled =
      [
        DSEx.Optimizer.COPRO.new(metric, breadth: 3, depth: 1),
        DSEx.Optimizer.MIPROv2.new(metric, trials: 3, demos_per_candidate: 1),
        DSEx.Optimizer.SIMBA.new(metric, steps: 2, demos_per_step: 1),
        DSEx.Optimizer.GEPA.new(metric, generations: 2),
        DSEx.Optimizer.SignatureOptimizer.new(metric)
      ]
      |> Enum.map(fn optimizer ->
        optimizer.__struct__.compile(optimizer, program, trainset, devset)
      end)

    assert Enum.all?(compiled, fn candidate ->
             {:ok, prediction} = DSEx.Predict.Predict.call(candidate, %{question: "2+2?"})
             DSEx.Prediction.get(prediction, :answer) == "4"
           end)
  end

  test "finetuning and GRPO are honest stubs without a real trainer backend" do
    lm = DSEx.Clients.Local.new("tiny", transport: Transport)
    program = DSEx.predict("question -> answer", lm: lm)
    metric = DSEx.Metrics.exact_match(:answer)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4") |> DSEx.Example.with_inputs(:question)
    ]

    result =
      DSEx.Optimizer.BootstrapFinetune.new(metric)
      |> DSEx.Optimizer.BootstrapFinetune.compile(program, trainset)

    assert %{program: %DSEx.Predict.Predict{}, error: :not_implemented} = result

    reward = fn example ->
      if DSEx.Example.get(example, :answer) == "4", do: 1.0, else: 0.0
    end

    assert {:error, :not_implemented} =
             DSEx.Optimizer.GRPO.new(reward)
             |> DSEx.Optimizer.GRPO.compile(program, trainset)
  end

  test "save/load, embeddings, and structured adapters work" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> ~s({"answer":"ok"}) end]
    }

    program = DSEx.predict("question -> answer", lm: lm, adapter: DSEx.Adapter.BAML)

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-program-#{System.unique_integer([:positive])}.json"
      )

    assert {:ok, prediction} = DSEx.Predict.Predict.call(program, %{question: "ship?"})
    assert DSEx.Prediction.get(prediction, :answer) == "ok"

    assert :ok = DSEx.Saving.save!(program, path)
    assert %DSEx.Predict.Predict{} = DSEx.Saving.load!(path)
    File.rm(path)

    assert {:ok, [vector]} =
             DSEx.Embeddings.embed(DSEx.Embeddings.BagOfWords, ["hello hello beam"], dims: 8)

    assert length(vector) == 8

    messages = DSEx.Adapter.TwoStep.format(DSEx.signature("q -> a"), %{q: "x"}, [])
    assert Enum.any?(messages, &String.contains?(&1.content, "plan"))
  end
end
