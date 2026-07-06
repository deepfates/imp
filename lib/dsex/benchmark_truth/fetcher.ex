defmodule DSEx.BenchmarkTruth.Fetcher do
  @moduledoc """
  Fetch canonical benchmark samples through HuggingFace's datasets-server API.

  The fetcher writes normalized JSONL files plus a manifest containing source
  URLs, split/config metadata, row counts, and SHA256 digests. It is designed
  for reproducible benchmark samples, not for mirroring entire datasets.
  """

  @hf_rows "https://datasets-server.huggingface.co/rows"

  @canonical_specs %{
    "gsm8k" => %{
      task: "gsm8k",
      dataset: "openai/gsm8k",
      config: "main",
      split: "test",
      input_keys: ["question"],
      normalizer: &__MODULE__.normalize_gsm8k/1
    },
    "hotpotqa" => %{
      task: "hotpotqa",
      dataset: "hotpotqa/hotpot_qa",
      config: "fullwiki",
      split: "validation",
      input_keys: ["question", "context"],
      normalizer: &__MODULE__.normalize_hotpotqa/1
    }
  }

  def canonical_specs, do: @canonical_specs

  def fetch(specs, opts \\ []) do
    out_dir = Keyword.get(opts, :out_dir, "benchmarks/data")
    offset = Keyword.get(opts, :offset, 0)
    length = Keyword.get(opts, :length, 50)
    transport = Keyword.get(opts, :transport, &http_get/1)

    File.mkdir_p!(out_dir)

    specs
    |> List.wrap()
    |> Enum.map(&canonical_spec!/1)
    |> Enum.map(fn spec ->
      fetch_one(spec, out_dir, offset, length, transport)
    end)
  end

  def normalize_gsm8k(row) do
    %{
      "question" => row["question"],
      "answer" => row["answer"],
      "canonical_answer" => extract_gsm8k_answer(row["answer"]),
      "source_task" => "gsm8k"
    }
  end

  def normalize_hotpotqa(row) do
    %{
      "id" => row["id"],
      "question" => row["question"],
      "answer" => row["answer"],
      "context" => flatten_hotpot_context(row["context"]),
      "supporting_facts" => row["supporting_facts"],
      "source_task" => "hotpotqa"
    }
  end

  def flatten_hotpot_context(%{"title" => titles, "sentences" => sentences})
      when is_list(titles) and is_list(sentences) do
    titles
    |> Enum.zip(sentences)
    |> Enum.map_join("\n", fn {title, lines} ->
      "#{title}: #{Enum.join(List.wrap(lines), " ")}"
    end)
  end

  def flatten_hotpot_context(context) when is_list(context) do
    Enum.map_join(context, "\n", &to_string/1)
  end

  def flatten_hotpot_context(context), do: to_string(context || "")

  def extract_gsm8k_answer(answer) do
    answer
    |> to_string()
    |> String.split("####")
    |> List.last()
    |> String.trim()
  end

  defp fetch_one(spec, out_dir, offset, length, transport) do
    url = rows_url(spec, offset, length)

    with {:ok, body} <- transport.(url),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rows} <- decode_rows(decoded) do
      records = Enum.map(rows, fn %{"row" => row} -> spec.normalizer.(row) end)
      basename = "#{spec.task}-#{spec.split}-#{offset}-#{length}"
      data_path = Path.join(out_dir, basename <> ".jsonl")
      manifest_path = Path.join(out_dir, basename <> ".manifest.json")
      jsonl = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
      File.write!(data_path, jsonl)

      manifest = %{
        "task" => spec.task,
        "dataset" => spec.dataset,
        "config" => spec.config,
        "split" => spec.split,
        "offset" => offset,
        "length" => length,
        "rows" => length(records),
        "source_url" => url,
        "fetched_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "sha256" => sha256(jsonl),
        "data_path" => data_path,
        "input_keys" => spec.input_keys
      }

      File.write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")
      %{task: spec.task, data_path: data_path, manifest_path: manifest_path, manifest: manifest}
    end
  end

  defp rows_url(spec, offset, length) do
    query =
      URI.encode_query(%{
        dataset: spec.dataset,
        config: spec.config,
        split: spec.split,
        offset: offset,
        length: length
      })

    @hf_rows <> "?" <> query
  end

  defp canonical_spec!(task) when is_atom(task), do: canonical_spec!(Atom.to_string(task))

  defp canonical_spec!(task) when is_binary(task) do
    Map.fetch!(@canonical_specs, task)
  end

  defp decode_rows(%{"rows" => rows}) when is_list(rows), do: {:ok, rows}
  defp decode_rows(other), do: {:error, {:missing_rows, other}}

  defp http_get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 -> {:ok, body}
      {:ok, {{_, status, _}, _headers, body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
