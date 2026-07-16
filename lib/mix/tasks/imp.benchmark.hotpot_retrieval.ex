defmodule Mix.Tasks.Imp.Benchmark.HotpotRetrieval do
  @moduledoc "Run the pinned provider-free HotPotQA shared-corpus retrieval differential."

  use Mix.Task

  @shortdoc "Run the source-bound HotPotQA retrieval differential"
  @config_path "benchmarks/config/hotpotqa-shared-retrieval-v1.json"
  @task_path "lib/mix/tasks/imp.benchmark.hotpot_retrieval.ex"
  @script_path "scripts/dspy_hotpot_retrieval.py"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, python: :string, require_clean: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")

    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config, bindings)

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, true),
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@dspy_commit}"},
        inputs: bindings
      )

    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("hotpot-retrieval"))
    File.mkdir_p!(out_dir)
    dspy = run_dspy!(Keyword.get(opts, :python, default_python()), out_dir)
    imp = imp_report(config)
    report = compare!(imp, dspy, bindings)

    path = Path.join(out_dir, "hotpot-retrieval-#{timestamp_slug()}.json")

    %{artifact: artifact, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, report, context)

    Mix.shell().info("HotPotQA shared retrieval report: #{path}")
    Mix.shell().info("matched rows: #{artifact["summary"]["matched_rows"]}/10")

    unless artifact["summary"]["provider_free_differential_complete"] do
      Mix.raise("HotPotQA shared retrieval differential failed; inspect #{path}")
    end
  end

  @doc false
  def validate_artifact!(artifact, opts \\ []) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config, bindings)

    if Keyword.get(opts, :require_clean, true) and
         get_in(artifact, ["run_context", "workspace", "state"]) != "clean" do
      raise ArgumentError, "HotPotQA retrieval evidence requires a clean source checkout"
    end

    unless get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings and
             artifact["summary"]["provider_free_differential_complete"] == true do
      raise ArgumentError, "HotPotQA retrieval artifact has stale, incomplete, or wrong bindings"
    end

    artifact
  end

  @doc false
  def source_bindings(config) do
    dataset = config["dataset"]

    %{
      "protocol_id" => config["protocol_id"],
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "config_sha256" => file_sha256!(@config_path),
      "dataset_sha256" => file_sha256!(dataset["path"]),
      "manifest_sha256" => file_sha256!(dataset["manifest"]),
      "authority_sha256" => file_sha256!(@authority_path),
      "dataset_rows" => dataset["rows"],
      "dataset_split" => dataset["split"],
      "top_k" => get_in(config, ["retrieval", "top_k"]),
      "dspy_commit" => @dspy_commit
    }
  end

  @doc false
  def compare_reports!(imp, dspy) when is_map(imp) and is_map(dspy) do
    config = read_json!(@config_path)
    compare!(imp, dspy, source_bindings(config))
  end

  defp imp_report(config) do
    rows = load_rows!(get_in(config, ["dataset", "path"]))
    corpus = build_corpus(rows)
    top_k = get_in(config, ["retrieval", "top_k"])
    retriever = Imp.Retrieve.Memory.new(corpus, k: top_k)

    results =
      Enum.map(rows, fn row ->
        {:ok, docs} = Imp.Retrieve.retrieve(retriever, row["question"], k: top_k)
        score_row(row, docs)
      end)

    %{
      "runner" => "imp-hotpot-shared-retrieval",
      "protocol_id" => config["protocol_id"],
      "corpus" => corpus_identity(corpus),
      "rows" => results,
      "summary" => summarize(results)
    }
  end

  defp validate_protocol!(config, bindings) do
    dataset = config["dataset"]
    manifest = read_json!(dataset["manifest"])
    actual_sha = String.trim_leading(bindings["dataset_sha256"], "sha256:")

    unless dataset["sha256"] == actual_sha and manifest["sha256"] == actual_sha and
             manifest["split"] == dataset["split"] and manifest["offset"] == dataset["offset"] and
             manifest["rows"] == dataset["rows"] and manifest["length"] == dataset["rows"] and
             manifest["data_path"] == dataset["path"] and dataset["rows"] == 10 and
             dataset["license"] == "CC-BY-SA-4.0" and
             manifest["license"] == dataset["license"] and
             manifest["license_notice"] == dataset["license_notice"] and
             File.regular?(dataset["license_notice"]) and
             get_in(config, ["retrieval", "top_k"]) == 5 and is_map(config["scorers"]) do
      raise ArgumentError,
            "HotPotQA protocol dataset, split, or scorer preregistration is invalid"
    end

    :ok
  end

  defp run_dspy!(python, out_dir) do
    path = Path.join(out_dir, "dspy-hotpot-retrieval-#{timestamp_slug()}.json")

    case System.cmd(python, [@script_path, "--out", path], stderr_to_stdout: true) do
      {_output, 0} -> read_json!(path)
      {output, status} -> Mix.raise("DSPy HotPotQA sidecar failed #{status}: #{output}")
    end
  end

  defp compare!(imp, dspy, bindings) do
    expected_source = %{
      "repository" => "stanfordnlp/dspy",
      "version" => "3.2.1",
      "commit" => @dspy_commit,
      "script_sha256" => bindings["script_sha256"],
      "config_sha256" => bindings["config_sha256"],
      "dataset_sha256" => bindings["dataset_sha256"],
      "manifest_sha256" => bindings["manifest_sha256"],
      "authority_sha256" => bindings["authority_sha256"]
    }

    unless dspy["source"] == expected_source and dspy["dspy_version"] == "3.2.1",
      do: Mix.raise("DSPy HotPotQA report has stale or wrong source bindings")

    imp_ids = Enum.map(imp["rows"], & &1["id"])
    dspy_ids = Enum.map(dspy["rows"] || [], & &1["id"])

    unless imp_ids == dspy_ids and length(imp_ids) == 10 and
             length(dspy_ids) == length(Enum.uniq(dspy_ids)) do
      Mix.raise("HotPotQA reports must contain the exact pinned ten-row split in order")
    end

    fields =
      ~w(id question gold_answer gold_supporting_titles retrieved_ids retrieved_titles context_sha256 supporting_fact_recall answer answer_em answer_f1)

    rows =
      Enum.zip_with(imp["rows"], dspy["rows"], fn imp_row, dspy_row ->
        matched = Map.take(imp_row, fields) == Map.take(dspy_row, fields)
        %{"id" => imp_row["id"], "matched" => matched, "imp" => imp_row, "dspy" => dspy_row}
      end)

    matched = Enum.count(rows, & &1["matched"])

    complete =
      matched == 10 and imp["corpus"] == dspy["corpus"] and imp["summary"] == dspy["summary"]

    %{
      "schema_version" => 1,
      "protocol_id" => imp["protocol_id"],
      "evidence_level" => "C2_provider_free_retrieval_differential",
      "source_bindings" => bindings,
      "corpus" => imp["corpus"],
      "imp" => Map.take(imp, ["runner", "summary"]),
      "dspy" => Map.take(dspy, ["runner", "dspy_version", "summary", "source"]),
      "rows" => rows,
      "summary" => %{
        "rows" => 10,
        "matched_rows" => matched,
        "provider_free_differential_complete" => complete,
        "mean_supporting_fact_recall" => imp["summary"]["mean_supporting_fact_recall"],
        "mean_answer_em" => imp["summary"]["mean_answer_em"],
        "mean_answer_f1" => imp["summary"]["mean_answer_f1"],
        "full_hotpotqa_effectiveness" => false
      },
      "limitations" => read_json!(@config_path)["limitations"]
    }
  end

  defp load_rows!(path) do
    path
    |> File.stream!()
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp build_corpus(rows) do
    {docs, _titles} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {docs, titles} ->
        row["context"]
        |> String.split("\n", trim: true)
        |> Enum.reduce({docs, titles}, fn line, {acc, seen} ->
          case String.split(line, ": ", parts: 2) do
            [title, _body] ->
              if MapSet.member?(seen, title) do
                {acc, seen}
              else
                {acc ++ [%{id: doc_id(title), title: title, text: line}], MapSet.put(seen, title)}
              end

            _ ->
              {acc, seen}
          end
        end)
      end)

    docs
  end

  defp score_row(row, docs) do
    titles = Enum.map(docs, & &1.title)
    gold_titles = row |> get_in(["supporting_facts", "title"]) |> Enum.uniq()
    found = Enum.count(gold_titles, &(&1 in titles))
    recall = found / length(gold_titles)
    context = Enum.map_join(docs, "\n\n", & &1.text)
    normalized_context = Imp.Metrics.normalize_text(context)
    gold_answer = row["answer"]

    answer =
      if String.contains?(normalized_context, Imp.Metrics.normalize_text(gold_answer)),
        do: gold_answer,
        else: ""

    %{
      "id" => row["id"],
      "question" => row["question"],
      "gold_answer" => gold_answer,
      "gold_supporting_titles" => gold_titles,
      "retrieved_ids" => Enum.map(docs, & &1.id),
      "retrieved_titles" => titles,
      "context_sha256" => sha256(context),
      "supporting_fact_recall" => recall,
      "answer" => answer,
      "answer_em" => if(Imp.Metrics.em(answer, gold_answer), do: 1.0, else: 0.0),
      "answer_f1" => Imp.Metrics.f1(answer, gold_answer)
    }
  end

  defp summarize(rows) do
    count = length(rows)

    %{
      "rows" => count,
      "mean_supporting_fact_recall" =>
        Enum.sum(Enum.map(rows, & &1["supporting_fact_recall"])) / count,
      "mean_answer_em" => Enum.sum(Enum.map(rows, & &1["answer_em"])) / count,
      "mean_answer_f1" => Enum.sum(Enum.map(rows, & &1["answer_f1"])) / count
    }
  end

  defp corpus_identity(corpus) do
    payload = Enum.map_join(corpus, fn doc -> "#{doc.id}\0#{doc.title}\0#{doc.text}\n" end)
    %{"documents" => length(corpus), "sha256" => sha256(payload)}
  end

  defp doc_id(title),
    do: title |> String.trim() |> String.downcase() |> sha256_raw() |> binary_part(0, 16)

  defp sha256(value), do: "sha256:" <> sha256_raw(value)
  defp sha256_raw(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp file_sha256!(path), do: path |> File.read!() |> sha256()
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp default_python do
    if File.exists?("tmp/dspy-parity-venv/bin/python"),
      do: Path.expand("tmp/dspy-parity-venv/bin/python"),
      else: "python3"
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
  end
end
