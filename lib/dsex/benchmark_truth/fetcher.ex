defmodule DSEx.BenchmarkTruth.Fetcher do
  @moduledoc false

  @hf_rows "https://datasets-server.huggingface.co/rows"
  @page_size 100
  @page_delay_ms 250
  @http_attempts 5
  @full_lengths %{
    "gsm8k" => 1319,
    "hotpotqa" => 7405
  }

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
      config: "distractor",
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
    page_delay_ms = Keyword.get(opts, :page_delay_ms, @page_delay_ms)

    File.mkdir_p!(out_dir)

    specs
    |> List.wrap()
    |> Enum.map(&canonical_spec!/1)
    |> Enum.map(fn spec ->
      fetch_one(spec, out_dir, offset, length, transport, page_delay_ms)
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

  defp fetch_one(spec, out_dir, offset, length, transport, page_delay_ms) do
    requested_length = requested_length(spec, length)

    with {:ok, rows, source_urls} <-
           fetch_pages(spec, offset, requested_length, transport, page_delay_ms, [], []) do
      records = Enum.map(rows, fn %{"row" => row} -> spec.normalizer.(row) end)
      basename = "#{spec.task}-#{spec.split}-#{offset}-#{requested_length}"
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
        "requested_length" => requested_length,
        "length" => length(records),
        "rows" => length(records),
        "source_urls" => source_urls,
        "fetched_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "sha256" => sha256(jsonl),
        "data_path" => data_path,
        "input_keys" => spec.input_keys
      }

      File.write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")
      %{task: spec.task, data_path: data_path, manifest_path: manifest_path, manifest: manifest}
    end
  end

  defp requested_length(spec, :full), do: Map.fetch!(@full_lengths, spec.task)
  defp requested_length(_spec, length), do: length

  defp fetch_pages(_spec, _offset, remaining, _transport, _page_delay_ms, rows, urls)
       when remaining <= 0 do
    {:ok, Enum.reverse(rows), Enum.reverse(urls)}
  end

  defp fetch_pages(spec, offset, remaining, transport, page_delay_ms, rows, urls) do
    page_length = min(remaining, @page_size)
    url = rows_url(spec, offset, page_length)

    with {:ok, body} <- transport.(url),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, page_rows} <- decode_rows(decoded) do
      next_rows = Enum.reverse(page_rows) ++ rows
      next_urls = [url | urls]

      if length(page_rows) < page_length do
        {:ok, Enum.reverse(next_rows), Enum.reverse(next_urls)}
      else
        maybe_sleep(page_delay_ms)

        fetch_pages(
          spec,
          offset + page_length,
          remaining - page_length,
          transport,
          page_delay_ms,
          next_rows,
          next_urls
        )
      end
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

  defp http_get(url), do: http_get(url, 1)

  defp http_get(url, attempt) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_, 429, _}, _headers, _body}} when attempt < @http_attempts ->
        maybe_sleep(1_000 * attempt)
        http_get(url, attempt + 1)

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_sleep(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp maybe_sleep(_ms), do: :ok

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
