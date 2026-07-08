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

  @local_specs %{
    "colors" => %{
      task: "colors",
      dataset: "dsex/local-colors",
      config: "main",
      split: "test",
      input_keys: ["input"],
      label_key: "label",
      rows: [
        %{"input" => "red", "label" => "warm"},
        %{"input" => "orange", "label" => "warm"},
        %{"input" => "yellow", "label" => "warm"},
        %{"input" => "blue", "label" => "cool"},
        %{"input" => "green", "label" => "cool"},
        %{"input" => "violet", "label" => "cool"}
      ]
    },
    "iris" => %{
      task: "iris",
      dataset: "dsex/local-iris",
      config: "balanced",
      split: "test",
      input_keys: ["features"],
      label_key: "label",
      rows: [
        %{
          "features" => "sepal_length=5.1 sepal_width=3.5 petal_length=1.4 petal_width=0.2",
          "label" => "setosa"
        },
        %{
          "features" => "sepal_length=4.9 sepal_width=3.0 petal_length=1.4 petal_width=0.2",
          "label" => "setosa"
        },
        %{
          "features" => "sepal_length=7.0 sepal_width=3.2 petal_length=4.7 petal_width=1.4",
          "label" => "versicolor"
        },
        %{
          "features" => "sepal_length=6.4 sepal_width=3.2 petal_length=4.5 petal_width=1.5",
          "label" => "versicolor"
        },
        %{
          "features" => "sepal_length=6.3 sepal_width=3.3 petal_length=6.0 petal_width=2.5",
          "label" => "virginica"
        },
        %{
          "features" => "sepal_length=5.8 sepal_width=2.7 petal_length=5.1 petal_width=1.9",
          "label" => "virginica"
        }
      ]
    },
    "iris_typo" => %{
      task: "iris_typo",
      dataset: "dsex/local-iris-typo",
      config: "balanced",
      split: "test",
      input_keys: ["features"],
      label_key: "label",
      rows: [
        %{
          "features" => "sepal lengh 5.1; sepal widht 3.5; petal lengh 1.4; petal widht 0.2",
          "label" => "setosa"
        },
        %{
          "features" => "sepal lengh 7.0; sepal widht 3.2; petal lengh 4.7; petal widht 1.4",
          "label" => "versicolor"
        },
        %{
          "features" => "sepal lengh 6.3; sepal widht 3.3; petal lengh 6.0; petal widht 2.5",
          "label" => "virginica"
        }
      ]
    },
    "heart_disease" => %{
      task: "heart_disease",
      dataset: "dsex/local-heart-disease",
      config: "risk-smoke",
      split: "test",
      input_keys: ["features"],
      label_key: "label",
      rows: [
        %{
          "features" => "age=29 chest_pain=typical max_hr=202 st_depression=0.0",
          "label" => "low_risk"
        },
        %{
          "features" => "age=41 chest_pain=atypical max_hr=172 st_depression=0.0",
          "label" => "low_risk"
        },
        %{
          "features" => "age=63 chest_pain=asymptomatic max_hr=108 st_depression=1.5",
          "label" => "high_risk"
        },
        %{
          "features" => "age=67 chest_pain=asymptomatic max_hr=108 st_depression=1.5",
          "label" => "high_risk"
        }
      ]
    },
    "retrieval_qa" => %{
      task: "retrieval_qa",
      dataset: "dsex/local-retrieval-qa",
      config: "mini-corpus",
      split: "test",
      input_keys: ["question"],
      label_key: "answer",
      corpus: [
        %{
          "id" => "city-france",
          "title" => "France",
          "text" => "Paris is the capital city of France."
        },
        %{
          "id" => "city-germany",
          "title" => "Germany",
          "text" => "Berlin is the capital city of Germany."
        },
        %{
          "id" => "beam-elixir",
          "title" => "Elixir",
          "text" => "Elixir runs on the BEAM virtual machine and uses lightweight processes."
        },
        %{
          "id" => "otp-supervision",
          "title" => "OTP",
          "text" =>
            "OTP supervision trees restart failed child processes according to a strategy."
        }
      ],
      rows: [
        %{
          "question" => "What is the capital city of France?",
          "answer" => "Paris",
          "evidence_ids" => ["city-france"]
        },
        %{
          "question" => "Which virtual machine does Elixir run on?",
          "answer" => "BEAM",
          "evidence_ids" => ["beam-elixir"]
        },
        %{
          "question" => "What do OTP supervision trees restart?",
          "answer" => "failed child processes",
          "evidence_ids" => ["otp-supervision"]
        }
      ]
    },
    "claim_verification" => %{
      task: "claim_verification",
      dataset: "dsex/local-claim-verification",
      config: "mini-corpus",
      split: "test",
      input_keys: ["claim"],
      label_key: "label",
      corpus: [
        %{
          "id" => "city-france",
          "title" => "France",
          "text" => "Paris is the capital city of France."
        },
        %{
          "id" => "city-germany",
          "title" => "Germany",
          "text" => "Berlin is the capital city of Germany."
        },
        %{
          "id" => "beam-elixir",
          "title" => "Elixir",
          "text" => "Elixir runs on the BEAM virtual machine and uses lightweight processes."
        },
        %{
          "id" => "otp-supervision",
          "title" => "OTP",
          "text" =>
            "OTP supervision trees restart failed child processes according to a strategy."
        }
      ],
      rows: [
        %{
          "claim" => "Paris is the capital city of France.",
          "label" => "supported",
          "evidence_ids" => ["city-france"]
        },
        %{
          "claim" => "Elixir runs on the JVM.",
          "label" => "refuted",
          "evidence_ids" => ["beam-elixir"]
        },
        %{
          "claim" => "OTP supervision trees restart failed child processes.",
          "label" => "supported",
          "evidence_ids" => ["otp-supervision"]
        }
      ]
    },
    "composition_orchestration" => %{
      task: "composition_orchestration",
      dataset: "dsex/local-composition-orchestration",
      config: "qa-mini",
      split: "test",
      input_keys: ["question"],
      label_key: "answer",
      rows: [
        %{"question" => "What is the capital city of France?", "answer" => "Paris"},
        %{"question" => "What is the capital city of Germany?", "answer" => "Berlin"},
        %{"question" => "What answer should an unknown branch return?", "answer" => "unknown"}
      ]
    },
    "ifbench_instruction_following" => %{
      task: "ifbench_instruction_following",
      dataset: "dsex/local-ifbench",
      config: "verifier-smoke",
      split: "test",
      input_keys: ["instruction"],
      label_key: "answer",
      rows: [
        %{
          "instruction" => "Return exactly OK.",
          "answer" => "OK",
          "constraints" => [%{"type" => "exact", "value" => "OK"}]
        },
        %{
          "instruction" => "Answer with the word BEAM and do not mention Python.",
          "answer" => "BEAM",
          "constraints" => [
            %{"type" => "contains", "value" => "BEAM"},
            %{"type" => "forbid", "value" => "Python"}
          ]
        },
        %{
          "instruction" => "Reply with at most three words and include Elixir.",
          "answer" => "Elixir works",
          "constraints" => [
            %{"type" => "contains", "value" => "Elixir"},
            %{"type" => "max_words", "value" => 3}
          ]
        }
      ]
    },
    "hard_math" => %{
      task: "hard_math",
      dataset: "dsex/local-hard-math",
      config: "aime-math-smoke",
      split: "test",
      input_keys: ["problem"],
      label_key: "answer",
      rows: [
        %{
          "problem" => "If 7x + 5 = 40, what is x?",
          "answer" => "5",
          "canonical_answer" => "5"
        },
        %{
          "problem" => "A rectangle has sides 9 and 14. What is its area?",
          "answer" => "126",
          "canonical_answer" => "126"
        },
        %{
          "problem" => "What is the value of 2^5 + 3^3?",
          "answer" => "59",
          "canonical_answer" => "59"
        }
      ]
    }
  }

  def canonical_specs, do: Map.merge(@canonical_specs, @local_specs)

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

    with {:ok, records, source_urls} <-
           fetch_records(spec, offset, requested_length, transport, page_delay_ms) do
      basename = "#{spec.task}-#{spec.split}-#{offset}-#{requested_length}"
      data_path = Path.join(out_dir, basename <> ".jsonl")
      manifest_path = Path.join(out_dir, basename <> ".manifest.json")
      jsonl = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
      File.write!(data_path, jsonl)
      corpus_info = maybe_write_corpus(spec, out_dir)

      manifest =
        %{
          "task" => spec.task,
          "dataset" => spec.dataset,
          "config" => spec.config,
          "split" => spec.split,
          "offset" => offset,
          "requested_length" => requested_length,
          "length" => length(records),
          "rows" => length(records),
          "source_urls" => source_urls,
          "source" =>
            if(Map.has_key?(spec, :rows), do: "local-fixture", else: "huggingface-rows"),
          "fetched_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "sha256" => sha256(jsonl),
          "data_path" => data_path,
          "input_keys" => spec.input_keys,
          "label_key" => Map.get(spec, :label_key, "answer")
        }
        |> Map.merge(corpus_info)

      File.write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")
      %{task: spec.task, data_path: data_path, manifest_path: manifest_path, manifest: manifest}
    end
  end

  defp requested_length(%{rows: rows}, :full), do: length(rows)
  defp requested_length(spec, :full), do: Map.fetch!(@full_lengths, spec.task)
  defp requested_length(_spec, length), do: length

  defp fetch_records(%{rows: rows} = spec, offset, requested_length, _transport, _page_delay_ms) do
    records =
      rows
      |> Enum.slice(offset, requested_length)
      |> Enum.map(&Map.put_new(&1, "source_task", spec.task))

    {:ok, records, ["local://#{spec.dataset}/#{spec.config}/#{spec.split}"]}
  end

  defp fetch_records(spec, offset, requested_length, transport, page_delay_ms) do
    with {:ok, rows, source_urls} <-
           fetch_pages(spec, offset, requested_length, transport, page_delay_ms, [], []) do
      {:ok, Enum.map(rows, fn %{"row" => row} -> spec.normalizer.(row) end), source_urls}
    end
  end

  defp maybe_write_corpus(%{corpus: corpus, task: task, config: config}, out_dir) do
    corpus_basename = "#{task}-#{config}-corpus"
    corpus_path = Path.join(out_dir, corpus_basename <> ".jsonl")
    corpus_jsonl = Enum.map_join(corpus, "\n", &Jason.encode!/1) <> "\n"
    File.write!(corpus_path, corpus_jsonl)

    %{
      "corpus_path" => corpus_path,
      "corpus_rows" => length(corpus),
      "corpus_sha256" => sha256(corpus_jsonl)
    }
  end

  defp maybe_write_corpus(_spec, _out_dir), do: %{}

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
    Map.fetch!(canonical_specs(), task)
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
