defmodule DeploymentHotPotQAGEPAExampleTest do
  use ExUnit.Case, async: false

  @example Path.expand("../examples/deployment", __DIR__)
  @data Path.join(@example, "data/hotpotqa-gepa")

  Code.require_file(Path.join(@example, "lib/imp_deployment/hotpotqa_pipeline.ex"))

  test "frozen rows are disjoint, content-bound, and stratified by declared type" do
    receipt = @data |> Path.join("receipt.json") |> File.read!() |> Jason.decode!()

    rows =
      for split <- ~w(train selection test), reduce: %{} do
        acc ->
          path = Path.join(@data, "#{split}.jsonl")
          assert sha256(path) == receipt["splits"][split]["sha256"]
          Map.put(acc, split, load_jsonl(path))
      end

    assert Enum.map(rows["train"], & &1["type"]) |> Enum.frequencies() == %{
             "bridge" => 6,
             "comparison" => 2
           }

    assert Enum.map(rows["selection"], & &1["type"]) |> Enum.frequencies() == %{
             "bridge" => 6,
             "comparison" => 2
           }

    assert Enum.map(rows["test"], & &1["type"]) |> Enum.frequencies() == %{
             "bridge" => 18,
             "comparison" => 6
           }

    all = rows |> Map.values() |> List.flatten()
    assert length(all) == 40
    assert length(Enum.uniq_by(all, & &1["source_id"])) == 40
    assert length(Enum.uniq_by(all, & &1["question_digest"])) == 40

    refute Enum.any?(all, fn row ->
             row["source_index"] in receipt["exposure"]["excluded_indices"]
           end)
  end

  test "consumer program performs four named stages over row-local context" do
    row = @data |> Path.join("train.jsonl") |> load_jsonl() |> hd()
    second_query = List.last(row["context"]["title"])
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)
          send(owner, {:rendered, rendered})

          %{
            summary_1: "first evidence",
            query_2: second_query,
            summary_2: "combined evidence",
            answer: "answer span"
          }
        end
      )

    program = ImpDeployment.HotPotQAPipeline.new()

    assert Enum.map(Imp.ProgramParameters.predictors(program), & &1.name) == [
             :summarize1,
             :create_query_hop2,
             :summarize2,
             :final_answer
           ]

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.call(program, %{question: row["question"], context: row["context"]})
             end)

    assert Imp.get(prediction, :answer) == "answer span"
    assert Imp.get(prediction, :passages_1) != []
    assert Imp.get(prediction, :passages_2) != []
    assert Enum.any?(Imp.get(prediction, :passages_2), &String.contains?(&1, second_query))

    rendered =
      Enum.map(1..4, fn _index ->
        assert_receive {:rendered, value}
        value
      end)

    assert Enum.any?(rendered, &String.contains?(&1, "first evidence"))

    source = File.read!(Path.join(@example, "lib/imp_deployment/hotpotqa_pipeline.ex"))
    refute source =~ "fetch(inputs, :answer)"
  end

  test "packaged metric has HotPot F1 and exact-match behavior" do
    assert Imp.Metrics.hotpot_f1("The Eiffel Tower", "Eiffel Tower") == 1.0
    assert Imp.Metrics.hotpot_f1("yes", "no") == 0.0
    assert Imp.Metrics.hotpot_f1("alpha alpha beta", "alpha beta") == 0.8
    assert Imp.Metrics.em("The Eiffel Tower", "Eiffel Tower")
    refute Imp.Metrics.em("Eiffel Tower extra", "Eiffel Tower")

    for file <- ~w(train selection test), row <- load_jsonl(Path.join(@data, "#{file}.jsonl")) do
      assert Imp.Metrics.hotpot_f1(row["answer"], row["answer"]) == 1.0
      assert Imp.Metrics.em(row["answer"], row["answer"])
    end
  end

  test "provider-disabled ordinary entry mutates all components and reloads fresh" do
    {output, 0} =
      System.cmd("mix", ["run", "--no-start", "hotpotqa_gepa.exs", "--", "--provider-disabled"],
        cd: @example,
        env: [{"IMP_PATH", "../.."}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["selected"] == "optimized"

    assert Enum.sort(result["named_predictors"]) ==
             ~w(create_query_hop2 final_answer summarize1 summarize2)

    assert result["observed_calls"] == %{
             "optimizer" => 8,
             "optimizer_metric_examples" => 32,
             "task" => 896
           }

    assert result["transport_caps"] == %{
             "optimizer_legal" => 12,
             "task_expected" => 912,
             "task_legal" => 960
           }

    assert result["input_token_upper_bounds"] == %{
             "task" => 12_288,
             "optimizer" => 147_456
           }

    assert_in_delta result["reservation_usd"], 49.655808, 1.0e-9
    assert result["fresh_service"] == "passed"
    assert result["prompt_bytes"]["task"] <= 8_192
    assert result["prompt_bytes"]["optimizer"] <= 131_072
  end

  test "entry uses public product APIs and names its BEAM-native selector" do
    source = File.read!(Path.join(@example, "hotpotqa_gepa.exs"))
    Code.string_to_quoted!(source)

    assert source =~ "Imp.Experiment.check"
    assert source =~ "module_selector: :all"
    assert source =~ "repetitions: 3"
    assert source =~ "ProgramServer.reload_parameters"
    assert source =~ "allow_fallbacks: false"
    assert source =~ "data_collection: \"deny\""
    assert source =~ "input_envelope: [max_bytes: max_bytes, reservation_tokens: envelope.input]"
    assert source =~ "Req.Response.new(status: 200"
    refute source =~ "max_input_tokens:"

    refute source =~ "Imp.BenchmarkTruth"
    refute source =~ "bench/"
    refute source =~ "Coordinator"
    refute source =~ "Ledger"
  end

  defp load_jsonl(path),
    do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end
