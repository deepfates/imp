defmodule Mix.Tasks.Dsex.Benchmark.Parity.Campaign do
  @moduledoc """
  Run a chunked DSEx-vs-DSPy parity campaign until coverage advances.

      mix dsex.benchmark.parity.campaign \\
        --model gpt-5.4-mini \\
        --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \\
        --chunk-size 100 \\
        --chunks 3 \\
        --max-concurrency 8

  The task always aggregates before choosing the next offset and after each
  completed chunk. It does not change the benchmark evidence standard; it only
  removes manual babysitting from long live campaigns.
  """

  use Mix.Task

  @shortdoc "Advance a chunked DSEx-vs-DSPy parity campaign"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          model: :string,
          gsm8k: :string,
          hotpotqa: :string,
          chunk_size: :integer,
          chunks: :integer,
          max_concurrency: :integer,
          out: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    model = Keyword.get(opts, :model) || Mix.raise("--model is required")
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    chunks = Keyword.get(opts, :chunks, 1)

    Enum.reduce_while(1..chunks, nil, fn chunk_index, _last ->
      aggregate = aggregate!(model, out_dir)

      if full?(aggregate) do
        Mix.shell().info("campaign already has full coverage for #{model}")
        {:halt, aggregate}
      else
        offset = next_offset(aggregate)

        Mix.shell().info(
          "running chunk #{chunk_index}/#{chunks} for #{model} at offset #{offset}"
        )

        run_chunk!(opts, model, offset, out_dir)
        {:cont, aggregate!(model, out_dir)}
      end
    end)
  end

  defp aggregate!(model, out_dir) do
    if Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-#{model_slug(model)}-*.json")) == [] do
      fresh_campaign()
    else
      run_aggregate!(model, out_dir)
      latest_campaign!(model, out_dir)
    end
  end

  defp run_aggregate!(model, out_dir) do
    Mix.Task.reenable("dsex.benchmark.parity.aggregate")

    Mix.Task.run("dsex.benchmark.parity.aggregate", [
      "--model",
      model,
      "--in",
      Path.join(out_dir, "dsex-dspy-parity-#{model_slug(model)}-*.json"),
      "--out",
      out_dir
    ])
  end

  defp fresh_campaign do
    %{
      "coverage" => %{"full" => false},
      "next_chunks" => [
        %{"task" => "gsm8k", "next_offset" => 0},
        %{"task" => "hotpotqa", "next_offset" => 0}
      ]
    }
  end

  defp latest_campaign!(model, out_dir) do
    out_dir
    |> Path.join("dsex-dspy-parity-campaign-#{model_slug(model)}-*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> List.last()
    |> case do
      nil -> Mix.raise("no campaign aggregate found for #{model}")
      path -> path |> File.read!() |> Jason.decode!()
    end
  end

  defp full?(aggregate), do: get_in(aggregate, ["coverage", "full"]) == true

  defp next_offset(aggregate) do
    aggregate
    |> Map.get("next_chunks", [])
    |> Enum.map(& &1["next_offset"])
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> 0 end)
  end

  defp run_chunk!(opts, model, offset, out_dir) do
    Mix.Task.reenable("dsex.benchmark.parity")

    args =
      [
        "--model",
        model,
        "--offset",
        to_string(offset),
        "--max-examples",
        to_string(Keyword.get(opts, :chunk_size, 100)),
        "--max-concurrency",
        to_string(Keyword.get(opts, :max_concurrency, 1)),
        "--out",
        out_dir
      ] ++
        dataset_args(opts) ++
        python_args(opts)

    Mix.Task.run("dsex.benchmark.parity", args)
  end

  defp dataset_args(opts) do
    []
    |> maybe_arg("--gsm8k", Keyword.get(opts, :gsm8k))
    |> maybe_arg("--hotpotqa", Keyword.get(opts, :hotpotqa))
  end

  defp maybe_arg(args, _name, nil), do: args
  defp maybe_arg(args, name, value), do: args ++ [name, value]

  defp python_args(opts) do
    case Keyword.get(opts, :python) do
      nil -> []
      python -> ["--python", python]
    end
  end

  defp model_slug(model), do: String.replace(model, ~r/[^0-9A-Za-z_.-]/, "_")
end
