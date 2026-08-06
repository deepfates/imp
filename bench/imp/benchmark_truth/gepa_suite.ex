defmodule Imp.BenchmarkTruth.GepaSuite do
  @moduledoc false

  alias Imp.Adapter.Chat

  alias Imp.BenchmarkTruth.{
    GepaComponentFeedback,
    GepaMetrics,
    HotpotMultiHop,
    HoverBM25,
    HoverMultiHop,
    IFBenchTwoStage,
    Papillon
  }

  @families Imp.BenchmarkTruth.GepaReplicationContract.required_families()

  @doc "Returns the six official GEPA benchmark family names in source order."
  def families, do: @families

  @doc "Loads and verifies one exported official family without opening held-out rows."
  def load!(dataset_root, family) when is_binary(dataset_root) and is_binary(family) do
    root = Imp.BenchmarkTruth.Paths.canonical_path!(dataset_root)
    spec = spec!(root, family)
    paths = split_paths(root, family)

    verify_split!(paths.train, spec, "train")
    verify_split!(paths.dev, spec, "dev")
    verify_split!(paths.test, spec, "test", decode?: false)
    validate_spec!(spec)

    %{
      spec: spec,
      paths: paths,
      train: Imp.Datasets.jsonl(paths.train, spec["input_keys"]),
      dev: Imp.Datasets.jsonl(paths.dev, spec["input_keys"]),
      test_count: row_count!(paths.test)
    }
  end

  @doc "Opens the already-verified held-out rows after optimization has returned."
  def load_test!(%{spec: spec, paths: paths, test_count: expected}) do
    bytes = File.read!(paths.test)

    expected_sha =
      get_in(spec, ["checksums", "test"]) || get_in(spec, ["split_checksums", "test"])

    actual_sha = "sha256:" <> sha256_bytes(bytes)

    if actual_sha != expected_sha do
      raise ArgumentError,
            "GEPA suite #{spec["family"]} held-out digest drift at decode barrier: " <>
              "expected #{expected_sha}, got #{actual_sha}"
    end

    records =
      bytes
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&Jason.decode!/1)

    rows = Imp.Datasets.from_records(records, spec["input_keys"], source: paths.test)

    if length(rows) != expected do
      raise ArgumentError,
            "GEPA suite held-out count drift for #{spec["family"]}: " <>
              "expected #{expected}, got #{length(rows)}"
    end

    rows
  end

  @doc "Builds the task program for one official family through Imp's ordinary modules."
  def program!(spec, lm, execution \\ %{})

  def program!(
        %{"upstream_metric" => "hover_utils.discrete_retrieval_eval"} = spec,
        lm,
        execution
      ) do
    retrieval = resolved_retrieval!(spec, execution)

    if get_in(execution, ["retrieval", "hover_upstream_bm25"]) == true do
      HoverMultiHop.new(lm, retrieval,
        upstream_python: true,
        python: get_in(execution, ["retrieval", "python"]) || "python3"
      )
    else
      HoverMultiHop.new(lm, retrieval)
    end
  end

  def program!(%{"program" => "HotpotMultiHop"} = spec, lm, execution) do
    retrieval = resolved_retrieval!(spec, execution)

    if get_in(execution, ["retrieval", "hover_upstream_bm25"]) == true do
      python = get_in(execution, ["retrieval", "python"]) || "python3"
      HotpotMultiHop.integration(lm, retrieval, python: python)
    else
      retriever = HoverBM25.new(retrieval, k: 7)
      HotpotMultiHop.new(lm, retriever)
    end
  end

  def program!(%{"program" => "IFBenchCoT2StageProgram"}, lm, _execution) do
    IFBenchTwoStage.new(lm, adapter: Chat)
  end

  def program!(%{"program" => "PAPILLON"}, lm, _execution) do
    Papillon.new(lm, lm: lm, adapter: Chat)
  end

  def program!(%{"program" => "CoT"} = spec, lm, _execution) do
    spec["signature"]
    |> Imp.signature(spec["instructions"])
    |> Imp.chain_of_thought(lm: lm, adapter: Chat)
  end

  def program!(spec, _lm, _execution) do
    raise ArgumentError,
          "unsupported GEPA suite program #{inspect(spec["program"])} " <>
            "for #{inspect(spec["family"])}"
  end

  @doc "Returns the source-faithful task metric for one family."
  def metric!(spec, opts \\ []), do: GepaMetrics.metric(spec, opts)

  @doc "Returns the source-faithful GEPA metric, including trace-sensitive scoring."
  def gepa_metric!(spec, opts \\ []), do: GepaMetrics.gepa_metric(spec, opts)

  @doc "Returns the source-faithful GEPA feedback metric for one family."
  def feedback_metric!(spec, opts \\ []), do: GepaMetrics.metric_with_feedback(spec, opts)

  @doc "Binds component-local GEPA feedback to the constructed program."
  def component_feedback!(spec, program, feedback_metric) do
    GepaComponentFeedback.callbacks!(spec, program, feedback_metric)
  end

  @doc false
  def component_feedback!(spec, program, feedback_metric, gepa_metric) do
    GepaComponentFeedback.callbacks!(spec, program, feedback_metric, gepa_metric)
  end

  def split_paths(dataset_root, family) do
    family_dir = Path.join(dataset_root, family)

    %{
      train: Path.join(family_dir, "train.jsonl"),
      dev: Path.join(family_dir, "dev.jsonl"),
      test: Path.join(family_dir, "test.jsonl")
    }
  end

  defp spec!(dataset_root, family) do
    unless family in @families do
      raise ArgumentError, "unknown official GEPA family: #{inspect(family)}"
    end

    specs =
      dataset_root
      |> Path.join("families.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("families")

    Enum.find(specs, &(&1["family"] == family)) ||
      raise ArgumentError, "GEPA dataset root missing family #{family}"
  end

  defp verify_split!(path, spec, split, opts \\ []) do
    expected_count = get_in(spec, ["split_counts", split])
    expected_sha = get_in(spec, ["checksums", split]) || get_in(spec, ["split_checksums", split])
    actual_sha = "sha256:" <> file_sha256(path)

    if actual_sha != expected_sha do
      raise ArgumentError,
            "GEPA suite #{spec["family"]} #{split} digest drift: " <>
              "expected #{expected_sha}, got #{actual_sha}"
    end

    if row_count!(path) != expected_count do
      raise ArgumentError,
            "GEPA suite #{spec["family"]} #{split} count drift: " <>
              "expected #{expected_count}, got #{row_count!(path)}"
    end

    if Keyword.get(opts, :decode?, true) do
      rows = Imp.Datasets.jsonl(path, spec["input_keys"])

      if length(rows) != expected_count do
        raise ArgumentError, "GEPA suite #{spec["family"]} #{split} decode drift"
      end
    end

    :ok
  end

  def validate_spec!(%{"upstream_metric" => "hover_utils.discrete_retrieval_eval"} = spec) do
    validate_retrieval!(spec, "Imp GEPA hoverBench row")
  end

  def validate_spec!(%{"program" => "HotpotMultiHop"} = spec) do
    validate_retrieval!(spec, "Imp GEPA HotpotQABench row")
  end

  def validate_spec!(_spec), do: :ok

  defp validate_retrieval!(spec, label) do
    unless valid_retrieval?(spec["retrieval"]) do
      raise ArgumentError,
            "#{label} requires source-exact BM25/wiki retrieval provenance"
    end
  end

  defp resolved_retrieval!(spec, execution) do
    label = "Imp GEPA #{spec["family"]} row"
    validate_retrieval!(spec, label)
    root = get_in(execution, ["retrieval", "root"])
    receipt = get_in(execution, ["retrieval", "authenticated_receipt"])

    retrieval =
      if is_binary(root) do
        spec["retrieval"]
        |> authenticated_retrieval(receipt)
        |> Map.update!("corpus_path", &Path.expand(&1, root))
        |> Map.update!("index_path", &Path.expand(&1, root))
      else
        spec["retrieval"]
      end

    HoverBM25.verify_source!(retrieval)
    retrieval
  end

  defp authenticated_retrieval(retrieval, nil), do: retrieval

  defp authenticated_retrieval(retrieval, %{
         "retrieval" => %{
           "extraction" => %{"corpus_sha256" => corpus_sha},
           "build" => %{"actual_tree_sha256" => index_sha}
         }
       }) do
    retrieval
    |> Map.put("corpus_checksum", "sha256:" <> corpus_sha)
    |> Map.put("index_checksum", "sha256:" <> index_sha)
  end

  defp authenticated_retrieval(_retrieval, receipt) when is_map(receipt) do
    unless valid_retrieval?(receipt) do
      raise ArgumentError, "Imp GEPA retrieval receipt is not an authenticated retrieval map"
    end

    receipt
  end

  defp valid_retrieval?(%{
         "kind" => "bm25s_wiki_abstracts_2017",
         "status" => "present",
         "corpus_checksum" => "sha256:" <> corpus_hash,
         "index_checksum" => "sha256:" <> index_hash
       }) do
    byte_size(corpus_hash) == 64 and byte_size(index_hash) == 64
  end

  defp valid_retrieval?(_other), do: false

  defp row_count!(path) do
    path
    |> File.stream!([], :line)
    |> Enum.count(&(String.trim(&1) != ""))
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> sha256_bytes()
  end

  defp sha256_bytes(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
