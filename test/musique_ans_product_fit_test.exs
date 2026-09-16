defmodule Imp.BenchmarkTruth.MusiqueAnsProductFitTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.MusiqueAns

  defp row do
    base = [
      %{
        "idx" => 0,
        "title" => "Bridge",
        "paragraph_text" => "The winner was Gamma.",
        "is_supporting" => true
      },
      %{
        "idx" => 1,
        "title" => "Final",
        "paragraph_text" => "Gamma received the prize.",
        "is_supporting" => true
      },
      %{
        "idx" => 2,
        "title" => "Noise",
        "paragraph_text" => "Delta attended.",
        "is_supporting" => false
      }
    ]

    noise =
      Enum.map(
        3..7,
        &%{
          "idx" => &1,
          "title" => "Noise #{&1}",
          "paragraph_text" => "Noise.",
          "is_supporting" => false
        }
      )

    %{
      "id" => "fixture-1",
      "question" => "Who won?",
      "answer" => "Gamma",
      "answer_aliases" => ["The Gamma"],
      "answerable" => true,
      "question_decomposition" => [%{"answer" => "do not expose"}],
      "paragraphs" => base ++ noise
    }
  end

  defp lm, do: stage_lm([2, 0, 1, 3, 4, 5, 6], [1, 2], "Gamma")

  defp stage_lm(indices, positions, answer),
    do:
      Imp.LM.Static.new(
        handler: fn messages, _ ->
          if Jason.encode!(messages) =~ "ordered_paragraph_idxs",
            do: %{ordered_paragraph_idxs: indices},
            else: %{answer: answer, support_positions: positions}
        end
      )

  test "task-owned selector and answerer enforce their semantic boundaries" do
    inputs = MusiqueAns.model_inputs(row())
    program = MusiqueAns.new(lm())

    assert Enum.map(Imp.ProgramParameters.predictors(program), & &1.name) == [
             :selector,
             :answerer
           ]

    rendered = Jason.encode!(inputs)
    refute rendered =~ ~r/is_supporting|answer_aliases|decomposition|do not expose/
    assert {:ok, prediction} = Imp.call(program, inputs)
    assert Imp.get(prediction, :support_idxs) == [0, 1]
    assert MusiqueAns.example(row()).input_keys == [:question, :paragraphs]

    assert {:error, {:musique_ans_failed, :invalid_top7_ranking}} =
             Imp.call(MusiqueAns.new(stage_lm([0, 0, 1, 2, 3, 4, 5], [0], "Gamma")), inputs)

    for positions <- [[0, 0], [0, 7]],
        do:
          assert(
            {:error, {:musique_ans_failed, :unknown_support_position}} =
              Imp.call(MusiqueAns.new(stage_lm(Enum.to_list(0..6), positions, "Gamma")), inputs)
          )
  end

  test "Elixir metric matches official answer and support edge semantics" do
    gold = MusiqueAns.example(row())

    cases = [
      {"Gamma!", [0, 1], %{answer_em: 1.0, answer_f1: 1.0, support_f1: 1.0}},
      {"the gamma gamma", [0], %{answer_em: 0.0, answer_f1: 2 / 3, support_f1: 2 / 3}},
      {"", [], %{answer_em: 0.0, answer_f1: 0.0, support_f1: 0.0}}
    ]

    for {answer, support, expected} <- cases, key <- Map.keys(expected) do
      actual = MusiqueAns.score(gold, Imp.Prediction.new(answer: answer, support_idxs: support))
      assert_in_delta actual[key], expected[key], 1.0e-12
    end

    assert MusiqueAns.support_f1([0, 0, 1], [0, 1]) == 1.0
    assert_raise ArgumentError, ~r/must be integers/, fn -> MusiqueAns.support_f1(["0"], [0]) end
  end

  test "real ReqLLM rendering preserves the two-stage information boundary" do
    owner = self()

    adapter = fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      send(owner, {:request, body})
      selector? = Jason.encode!(body) =~ "ordered_paragraph_idxs"

      content =
        if selector?,
          do:
            "[[ ## ordered_paragraph_idxs ## ]]\n[2, 0, 1, 3, 4, 5, 6]\n\n[[ ## completed ## ]]",
          else:
            "[[ ## answer ## ]]\nGamma\n\n[[ ## support_positions ## ]]\n[1, 2]\n\n[[ ## completed ## ]]"

      response = %{
        "id" => "provider-disabled",
        "object" => "chat.completion",
        "model" => "provider-disabled",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      {request, Req.Response.new(status: 200, body: response)}
    end

    lm =
      Imp.req_llm(
        %{
          provider: :openrouter,
          id: "provider-disabled",
          model: "provider-disabled",
          base_url: "http://127.0.0.1:1/v1"
        },
        api_key: "none",
        cache: false,
        max_retries: 0,
        req_http_options: [adapter: adapter, retry: false, max_retries: 0]
      )

    assert {:ok, prediction} = Imp.call(MusiqueAns.new(lm), MusiqueAns.model_inputs(row()))
    assert Imp.get(prediction, :support_idxs) == [0, 1]
    requests = for _ <- 1..2, do: receive(do: ({:request, body} -> body))
    rendered = Jason.encode!(requests)
    refute rendered =~ ~r/answer_aliases|is_supporting|decomposition|do not expose/

    answerer =
      requests |> Enum.at(1) |> get_in(["messages"]) |> List.last() |> Map.fetch!("content")

    expected =
      Enum.map([2, 0, 1, 3, 4, 5, 6], &Enum.at(MusiqueAns.model_inputs(row()).paragraphs, &1))

    offsets =
      for paragraph <- expected do
        # A paragraph is a map, rendered the way the adapter renders every dict.
        serialized = Imp.Adapter.Chat.format_value(paragraph)
        {offset, _} = :binary.match(answerer, serialized)
        assert length(:binary.matches(answerer, serialized)) == 1
        offset
      end

    assert offsets == Enum.sort(offsets)
    refute answerer =~ "\"idx\" => 7"
  end

  test "strict planted mechanical objective persists both mutations and serves fresh" do
    lm = optimizer_lm()
    program = MusiqueAns.new(lm)

    rows =
      for {split, index} <- Enum.with_index(~w(train selection test)),
          do:
            row()
            |> Map.put("id", "#{split}-#{index}")
            |> Map.put("question", "Who won #{split}?")
            |> MusiqueAns.example()

    metric = fn example, prediction ->
      score = MusiqueAns.score(example, prediction)
      score.answer_em + score.support_f1
    end

    proposer = fn candidate, _records, components ->
      updates = %{
        selector: "Rank decisive evidence first.",
        answerer: "Answer Gamma from evidence."
      }

      %{new_texts: Map.take(Map.merge(candidate, updates), components)}
    end

    optimizer =
      Imp.Optimizer.GEPA.new(metric,
        generations: 2,
        module_selector: :round_robin,
        reflection_strategy: proposer
      )

    data =
      Imp.Experiment.Data.new(
        train: [Enum.at(rows, 0)],
        selection: [Enum.at(rows, 1)],
        test: [Enum.at(rows, 2)],
        id: :id
      )

    assert {:ok, result} =
             Imp.Experiment.check(program, optimizer, data, metric,
               artifact_id: "musique-provider-disabled",
               compare_baseline_on_test: true
             )

    assert result.selected == :optimized

    root = Path.join(System.tmp_dir!(), "musique-fit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    artifact = Path.join(root, "artifact.json")
    receipt = Path.join(root, "fresh.json")
    :ok = Imp.Optimizer.Artifact.write!(result.artifact, artifact)
    assert Jason.decode!(File.read!(artifact))["schema_version"] == 3

    applied =
      artifact
      |> Imp.Optimizer.Artifact.read!()
      |> Imp.Optimizer.Artifact.apply(MusiqueAns.new(lm))

    before =
      Map.new(
        Imp.ProgramParameters.predictors(program),
        &{&1.name, &1.predictor.signature.instructions}
      )

    changed =
      for item <- Imp.ProgramParameters.predictors(applied),
          item.predictor.signature.instructions != before[item.name],
          do: item.name

    assert changed == [:selector, :answerer]

    code = """
    Code.require_file("examples/deployment/lib/imp_deployment/program_server.ex")
    lm = #{optimizer_lm_source()}
    program = Imp.Optimizer.Artifact.apply(Imp.Optimizer.Artifact.read!(#{inspect(artifact)}), Imp.BenchmarkTruth.MusiqueAns.new(lm))
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, server} = ImpDeployment.ProgramServer.start_link(program: program, lm: lm, task_supervisor: supervisor,
      executor: fn selected, _lm, inputs -> Imp.call(selected, inputs) end, name: nil)
    {:ok, prediction} = ImpDeployment.ProgramServer.call(server, #{inspect(MusiqueAns.model_inputs(row()))}, 5_000)
    File.write!(#{inspect(receipt)}, Jason.encode!(Imp.Prediction.to_map(prediction)))
    """

    {_, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert Jason.decode!(File.read!(receipt)) == %{"answer" => "Gamma", "support_idxs" => [0, 1]}
  end

  @tag :evidence_infrastructure
  test "entry authenticates train while preserving prior dev and test audit exposure" do
    archive = System.fetch_env!("MUSIQUE_ARCHIVE")
    data_root = System.fetch_env!("MUSIQUE_DATA_ROOT")
    source_root = System.fetch_env!("MUSIQUE_SOURCE_ROOT")
    manifest = Jason.decode!(File.read!("benchmarks/authority_sources/musique-ans-922ac98.json"))
    {head, 0} = System.cmd("git", ["-C", source_root, "rev-parse", "HEAD"])
    assert String.trim(head) == manifest["commit"]

    {"", 0} =
      System.cmd("git", ["-C", source_root, "status", "--porcelain", "--untracked-files=no"])

    for item <- manifest["files"],
        do:
          assert(
            Base.encode16(
              :crypto.hash(
                :sha256,
                File.read!(Path.join(source_root, item["path"]))
              ),
              case: :lower
            ) == item["sha256"]
          )

    verified = MusiqueAns.verify_data!(archive, data_root)

    assert verified.train_rows == 19_938

    assert verified.dev == %{
             decoded_in_this_entry: false,
             rows: 2_417,
             sha256: "15fa63794d18a94ce12411aca6e2327e65b6e83b0b1490efab3f1962e48abf3b",
             status: :audit_exposed_model_optimizer_treatment_unseen
           }

    assert verified.test.decoded_in_this_entry == false
    assert verified.test.status == :audit_exposed_inputs_only_labels_hidden_treatment_excluded

    program = MusiqueAns.new(lm())
    sample = verified.train |> Enum.sort_by(&:crypto.hash(:sha256, &1["id"])) |> Enum.take(128)

    bytes = fn predictor, inputs ->
      Imp.Adapter.Chat.format(predictor.signature, inputs, [])
      |> Enum.map(&%{role: to_string(&1.role), content: &1.content})
      |> Jason.encode!()
      |> byte_size()
    end

    selector = Enum.map(sample, &bytes.(program.selector, MusiqueAns.model_inputs(&1)))

    answerer =
      Enum.map(sample, fn item ->
        inputs = MusiqueAns.model_inputs(item)

        bytes.(program.answerer, %{
          question: inputs.question,
          selected_paragraphs: Enum.take(inputs.paragraphs, 7)
        })
      end)

    assert {percentile(selector, 50), percentile(selector, 95), Enum.max(selector)} ==
             {12_345, 16_047, 17_218}

    assert {percentile(answerer, 50), percentile(answerer, 95), Enum.max(answerer)} ==
             {5_089, 6_390, 7_294}
  end

  @tag :evidence_infrastructure
  test "all 19,938 train rows and edge mutations match the official Python scorer" do
    data_root = System.fetch_env!("MUSIQUE_DATA_ROOT")
    source_root = System.fetch_env!("MUSIQUE_SOURCE_ROOT")

    rows =
      data_root
      |> Path.join("musique_ans_v1.0_train.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    records =
      Enum.with_index(rows, fn row, index ->
        support =
          for paragraph <- row["paragraphs"], paragraph["is_supporting"], do: paragraph["idx"]

        predicted_answer =
          case rem(index, 5) do
            0 -> row["answer"]
            1 -> String.upcase(row["answer"]) <> "!"
            2 -> List.first(row["answer_aliases"]) || row["answer"]
            3 -> ""
            4 -> row["answer"] |> String.split() |> List.first()
          end

        predicted_support =
          case rem(index, 4) do
            0 -> support
            1 -> Enum.drop(support, 1)
            2 -> support ++ [999]
            3 -> []
          end

        %{
          answer: row["answer"],
          answer_aliases: row["answer_aliases"],
          support_idxs: support,
          predicted_answer: predicted_answer,
          predicted_support_idxs: predicted_support
        }
      end) ++
        [
          %{
            answer: "The A",
            answer_aliases: [],
            support_idxs: [],
            predicted_answer: "a!",
            predicted_support_idxs: []
          },
          %{
            answer: "red red blue",
            answer_aliases: [],
            support_idxs: [1, 2],
            predicted_answer: "red blue blue",
            predicted_support_idxs: [2, 3]
          }
        ]

    input =
      Path.join(System.tmp_dir!(), "musique-scores-#{System.unique_integer([:positive])}.jsonl")

    File.write!(input, Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n")))
    on_exit(fn -> File.rm(input) end)

    {output, 0} =
      System.cmd(
        "python3",
        [
          "scripts/musique_ans_product_fit_upstream.py",
          "--score-lines",
          "--musique-root",
          source_root,
          "--input",
          input
        ],
        stderr_to_stdout: true
      )

    official = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    local =
      Enum.map(records, fn record ->
        gold =
          Imp.Example.new(
            answer: record.answer,
            answer_aliases: record.answer_aliases,
            support_idxs: record.support_idxs
          )

        MusiqueAns.score(
          gold,
          Imp.Prediction.new(
            answer: record.predicted_answer,
            support_idxs: record.predicted_support_idxs
          )
        )
      end)

    assert length(official) == 19_940

    for {left, right} <- Enum.zip(local, official), key <- ~w(answer_em answer_f1 support_f1) do
      assert_in_delta(left[String.to_existing_atom(key)], right[key], 1.0e-12)
    end
  end

  @tag :evidence_infrastructure
  @tag :requires_dspy_capture
  test "pinned DSPy uses the same two semantic stages through real LiteLLM rendering" do
    {output, 0} =
      System.cmd(
        Path.expand("tmp/dspy-parity-venv/bin/python"),
        [
          "scripts/musique_ans_product_fit_upstream.py",
          "--request-proof",
          "--dspy-root",
          "tmp/dspy-3.2.1"
        ],
        stderr_to_stdout: true
      )

    payload = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert payload["predictors"] == ["selector", "answerer"]
    assert payload["prediction"] == %{"answer" => "Gamma", "support_idxs" => [0, 1]}

    expected =
      Enum.map([2, 0, 1, 3, 4, 5, 6], &Enum.at(MusiqueAns.model_inputs(row()).paragraphs, &1))

    assert payload["answerer_input"] == expected
    refute Jason.encode!(payload["requests"]) =~ ~r/answer_aliases|is_supporting|decomposition/
  end

  defp optimizer_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        prompt = Jason.encode!(messages)

        cond do
          prompt =~ "ordered_paragraph_idxs" ->
            %{
              ordered_paragraph_idxs:
                if(prompt =~ "decisive evidence",
                  do: [0, 1, 2, 3, 4, 5, 6],
                  else: [2, 0, 1, 3, 4, 5, 6]
                )
            }

          prompt =~ "Answer Gamma" ->
            %{answer: "Gamma", support_positions: [0, 1]}

          true ->
            %{answer: "wrong", support_positions: [0, 1]}
        end
      end
    )
  end

  defp optimizer_lm_source do
    "Imp.LM.Static.new(handler: fn messages, _opts -> prompt = Jason.encode!(messages); cond do " <>
      "prompt =~ \"ordered_paragraph_idxs\" -> %{ordered_paragraph_idxs: if(prompt =~ \"decisive evidence\", do: [0,1,2,3,4,5,6], else: [2,0,1,3,4,5,6])}; " <>
      "prompt =~ \"Answer Gamma\" -> %{answer: \"Gamma\", support_positions: [0,1]}; " <>
      "true -> %{answer: \"wrong\", support_positions: [0,1]} end end)"
  end

  defp percentile(values, percent),
    do: values |> Enum.sort() |> Enum.at(ceil(length(values) * percent / 100) - 1)
end
