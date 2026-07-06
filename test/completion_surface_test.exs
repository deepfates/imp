defmodule CompletionSurfaceTest do
  use ExUnit.Case

  defmodule Transport do
    @behaviour Dachshund.HTTP

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
    Dachshund.configure(lm: nil, adapter: Dachshund.Adapter.Chat, retriever: nil)
    :ok
  end

  test "openai-compatible provider clients build verifiable HTTP contracts" do
    lm = Dachshund.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: Transport)

    assert {:ok, "Answer: shipped"} =
             Dachshund.LM.generate(lm, [%{role: :user, content: "hello"}], temperature: 0)

    assert_received {:http_post, "https://api.openai.com/v1/chat/completions", headers, payload}
    assert {"authorization", "Bearer sk-test"} in headers
    assert payload["model"] == "gpt-test"
    assert [%{"role" => "user", "content" => "hello"}] = payload["messages"]
    assert payload["temperature"] == 0
  end

  test "program of thought evaluates arithmetic in a safe sandbox" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2 + 1"} end]
    }

    program = Dachshund.Predict.ProgramOfThought.new("x -> answer", lm: lm)

    assert {:ok, prediction} = Dachshund.Predict.ProgramOfThought.call(program, %{x: 3})
    assert Dachshund.Prediction.get(prediction, :answer) == 7

    assert {:error, {:unsafe_ast, _}} =
             Dachshund.Sandbox.eval("System.cmd(\"rm\", [\"-rf\", \"/\"])")
  end

  test "streaming exposes predictions as an enumerable" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]
    }

    program = Dachshund.predict("question -> answer", lm: lm)

    assert Dachshund.Streaming.collect(program, %{question: "runtime?"}) == "beam"

    assert Enum.take(Dachshund.Streaming.stream(program, %{question: "runtime?"}), 2) == [
             "b",
             "e"
           ]
  end

  test "dataset loaders produce examples with declared inputs" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dachshund-dataset-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, ~s({"question":"2+2?","answer":"4"}\n{"question":"3+3?","answer":"6"}\n))

    examples = Dachshund.Datasets.gsm8k(path)
    assert length(examples) == 2
    assert Dachshund.Example.to_map(Dachshund.Example.inputs(hd(examples))) == %{question: "2+2?"}

    File.rm(path)
  end

  test "advanced optimizers return executable compiled programs" do
    lm = %{module: Dachshund.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = Dachshund.predict("question -> answer", lm: lm)

    trainset = [
      Dachshund.example(question: "2+2?", answer: "4")
      |> Dachshund.Example.with_inputs(:question),
      Dachshund.example(question: "square root of 16?", answer: "4")
      |> Dachshund.Example.with_inputs(:question)
    ]

    devset = [
      Dachshund.example(question: "2 plus 2?", answer: "4")
      |> Dachshund.Example.with_inputs(:question)
    ]

    metric = Dachshund.Metrics.exact_match(:answer)

    compiled =
      [
        Dachshund.Optimizer.COPRO.new(metric, breadth: 3, depth: 1),
        Dachshund.Optimizer.MIPROv2.new(metric, trials: 3, demos_per_candidate: 1),
        Dachshund.Optimizer.SIMBA.new(metric, steps: 2, demos_per_step: 1),
        Dachshund.Optimizer.GEPA.new(metric, generations: 2),
        Dachshund.Optimizer.SignatureOptimizer.new(metric)
      ]
      |> Enum.map(fn optimizer ->
        optimizer.__struct__.compile(optimizer, program, trainset, devset)
      end)

    assert Enum.all?(compiled, fn candidate ->
             {:ok, prediction} = Dachshund.Predict.Predict.call(candidate, %{question: "2+2?"})
             Dachshund.Prediction.get(prediction, :answer) == "4"
           end)
  end

  test "finetuning and GRPO create provider-neutral training jobs" do
    lm = Dachshund.Clients.Local.new("tiny", transport: Transport)
    program = Dachshund.predict("question -> answer", lm: lm)
    metric = Dachshund.Metrics.exact_match(:answer)

    trainset = [
      Dachshund.example(question: "2+2?", answer: "4") |> Dachshund.Example.with_inputs(:question)
    ]

    result =
      Dachshund.Optimizer.BootstrapFinetune.new(metric)
      |> Dachshund.Optimizer.BootstrapFinetune.compile(program, trainset)

    assert %Dachshund.Clients.TrainingJob{status: :succeeded, result_model: "tiny:finetuned"} =
             result.job

    reward = fn example ->
      if Dachshund.Example.get(example, :answer) == "4", do: 1.0, else: 0.0
    end

    assert {:ok,
            %Dachshund.Clients.TrainingJob{status: :succeeded, training_data: [%{reward: 1.0}]}} =
             Dachshund.Optimizer.GRPO.new(reward)
             |> Dachshund.Optimizer.GRPO.compile(program, trainset)
  end

  test "save/load, embeddings, and structured adapters work" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> ~s({"answer":"ok"}) end]
    }

    program = Dachshund.predict("question -> answer", lm: lm, adapter: Dachshund.Adapter.BAML)

    path =
      Path.join(
        System.tmp_dir!(),
        "dachshund-program-#{System.unique_integer([:positive])}.json"
      )

    assert {:ok, prediction} = Dachshund.Predict.Predict.call(program, %{question: "ship?"})
    assert Dachshund.Prediction.get(prediction, :answer) == "ok"

    assert :ok = Dachshund.Saving.save!(program, path)
    assert %Dachshund.Predict.Predict{} = Dachshund.Saving.load!(path)
    File.rm(path)

    assert {:ok, [vector]} =
             Dachshund.Embeddings.embed(Dachshund.Embeddings.BagOfWords, ["hello hello beam"],
               dims: 8
             )

    assert length(vector) == 8

    messages = Dachshund.Adapter.TwoStep.format(Dachshund.signature("q -> a"), %{q: "x"}, [])
    assert Enum.any?(messages, &String.contains?(&1.content, "plan"))
  end
end
