defmodule Mix.Tasks.Dsex.Benchmark.Parity.Campaign do
  @moduledoc """
  Run a chunked DSEx-vs-DSPy parity campaign until coverage advances.

      mix dsex.benchmark.parity.campaign \\
        --model gpt-5.4-mini \\
        --dspy-model responses/gpt-5.4-mini \\
        --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \\
        --chunk-size 100 \\
        --chunks 3 \\
        --target-coverage 1000 \\
        --max-concurrency 8

  The task always aggregates before choosing the next offset and after each
  completed chunk. It does not change the benchmark evidence standard; it only
  removes manual babysitting from long live campaigns. DSEx chunks are scoped to
  the ReqLLM provider identity. Use `--target-coverage` to advance a campaign
  to a concrete total paired-row coverage target without hand-counting chunks.
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
          dspy_model: :string,
          gsm8k: :string,
          hotpotqa: :string,
          chunk_size: :integer,
          chunks: :integer,
          target_coverage: :integer,
          max_concurrency: :integer,
          out: :string,
          campaign_id: :string,
          temperature: :float,
          max_tokens: :integer,
          reasoning_effort: :string,
          runner_order: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    model = Keyword.get(opts, :model) || Mix.raise("--model is required")
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    chunks = Keyword.get(opts, :chunks, 1)
    campaign_id = Keyword.get(opts, :campaign_id) || default_campaign_id(model)

    Mix.shell().info("campaign id: #{campaign_id}")

    Enum.reduce_while(1..chunks, nil, fn chunk_index, _last ->
      aggregate = aggregate!(model, out_dir, campaign_id)

      cond do
        full?(aggregate) ->
          Mix.shell().info("campaign already has full coverage for #{model}")
          {:halt, aggregate}

        target_reached?(aggregate, opts) ->
          Mix.shell().info(
            "campaign reached target coverage #{coverage(aggregate)}/#{Keyword.fetch!(opts, :target_coverage)} for #{model}"
          )

          {:halt, aggregate}

        true ->
          chunk_plan = next_chunk_plan(aggregate, dataset_paths(opts))
          chunk_size = planned_chunk_size(aggregate, chunk_plan, opts)
          chunk_opts = Keyword.put(opts, :chunk_size, chunk_size)

          Mix.shell().info(
            "running chunk #{chunk_index}/#{chunks} for #{model}: #{chunk_plan_summary(chunk_plan)} max_examples=#{chunk_size}"
          )

          run_chunk!(chunk_opts, model, campaign_id, chunk_plan, out_dir)
          {:cont, aggregate!(model, out_dir, campaign_id)}
      end
    end)
  end

  defp target_reached?(aggregate, opts) do
    case Keyword.get(opts, :target_coverage) do
      nil -> false
      target when is_integer(target) and target > 0 -> coverage(aggregate) >= target
      target -> Mix.raise("--target-coverage must be a positive integer, got: #{inspect(target)}")
    end
  end

  defp coverage(aggregate), do: get_in(aggregate, ["coverage", "covered"]) || 0

  @doc false
  def planned_chunk_size(aggregate, chunk_plan, opts) do
    configured = Keyword.get(opts, :chunk_size, 100)

    target_limited =
      case Keyword.get(opts, :target_coverage) do
        nil ->
          configured

        target when is_integer(target) and target > 0 ->
          remaining_to_target = max(target - coverage(aggregate), 1)
          min(configured, ceil(remaining_to_target / max(length(chunk_plan), 1)))

        target ->
          Mix.raise("--target-coverage must be a positive integer, got: #{inspect(target)}")
      end

    remaining_limited =
      chunk_plan
      |> Enum.map(& &1.remaining)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> target_limited
        remaining -> min(target_limited, Enum.max(remaining))
      end

    max(remaining_limited, 1)
  end

  defp aggregate!(model, out_dir, campaign_id) do
    if campaign_reports(model, out_dir, campaign_id) == [] do
      fresh_campaign()
    else
      run_aggregate!(model, out_dir, campaign_id)
      latest_campaign!(model, out_dir, campaign_id)
    end
  end

  defp run_aggregate!(model, out_dir, campaign_id) do
    Mix.Task.reenable("dsex.benchmark.parity.aggregate")

    Mix.Task.run("dsex.benchmark.parity.aggregate", [
      "--provider",
      "req_llm",
      "--model",
      model,
      "--in",
      Path.join(out_dir, "dsex-dspy-parity-#{model_slug(model)}-*.json"),
      "--campaign-id",
      campaign_id,
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

  defp latest_campaign!(model, out_dir, campaign_id) do
    out_dir
    |> Path.join("dsex-dspy-parity-campaign-req_llm-#{model_slug(model)}-*.json")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      path |> File.read!() |> Jason.decode!() |> Map.get("campaign_id") == campaign_id
    end)
    |> Enum.sort()
    |> List.last()
    |> case do
      nil -> Mix.raise("no campaign aggregate found for #{model}")
      path -> path |> File.read!() |> Jason.decode!()
    end
  end

  defp full?(aggregate), do: get_in(aggregate, ["coverage", "full"]) == true

  @doc false
  def next_chunk_plan(aggregate, dataset_paths) do
    candidates =
      aggregate
      |> Map.get("next_chunks", [])
      |> Enum.filter(
        &(task_atom(&1["task"]) && Map.has_key?(dataset_paths, task_atom(&1["task"])))
      )
      |> Enum.reject(&is_nil(&1["next_offset"]))

    if candidates == [] do
      Mix.raise("campaign has no runnable missing chunks for supplied datasets")
    end

    offset =
      candidates
      |> Enum.map(& &1["next_offset"])
      |> Enum.min()

    candidates
    |> Enum.filter(&(&1["next_offset"] == offset))
    |> Enum.map(fn chunk ->
      task = task_atom(chunk["task"])

      %{
        task: task,
        path: Map.fetch!(dataset_paths, task),
        offset: offset,
        remaining: chunk["remaining"]
      }
    end)
  end

  defp run_chunk!(opts, model, campaign_id, chunk_plan, out_dir) do
    Mix.Task.reenable("dsex.benchmark.parity")

    Mix.Task.run(
      "dsex.benchmark.parity",
      chunk_args(opts, model, campaign_id, chunk_plan, out_dir)
    )
  end

  @doc false
  def chunk_args(opts, model, campaign_id, chunk_plan, out_dir) do
    offset = chunk_plan |> List.first() |> Map.fetch!(:offset)

    [
      "--model",
      model,
      "--campaign-id",
      campaign_id,
      "--offset",
      to_string(offset),
      "--max-examples",
      to_string(Keyword.get(opts, :chunk_size, 100)),
      "--max-concurrency",
      to_string(Keyword.get(opts, :max_concurrency, 1)),
      "--out",
      out_dir
    ] ++
      runner_order_args(opts, offset) ++
      generation_args(opts) ++
      dspy_model_args(opts) ++
      dataset_args(chunk_plan) ++
      python_args(opts)
  end

  defp dataset_paths(opts) do
    %{}
    |> maybe_path(:gsm8k, Keyword.get(opts, :gsm8k))
    |> maybe_path(:hotpotqa, Keyword.get(opts, :hotpotqa))
  end

  defp maybe_path(paths, _task, nil), do: paths
  defp maybe_path(paths, task, path), do: Map.put(paths, task, path)

  defp task_atom("gsm8k"), do: :gsm8k
  defp task_atom("hotpotqa"), do: :hotpotqa
  defp task_atom(_other), do: nil

  defp dataset_args(chunk_plan) do
    Enum.flat_map(chunk_plan, fn %{task: task, path: path} -> ["--#{task}", path] end)
  end

  defp generation_args(opts) do
    []
    |> maybe_arg("--temperature", Keyword.get(opts, :temperature))
    |> maybe_arg("--max-tokens", Keyword.get(opts, :max_tokens))
    |> maybe_arg("--reasoning-effort", Keyword.get(opts, :reasoning_effort))
  end

  defp dspy_model_args(opts) do
    []
    |> maybe_arg("--dspy-model", Keyword.get(opts, :dspy_model))
  end

  defp maybe_arg(args, _name, nil), do: args
  defp maybe_arg(args, name, value), do: args ++ [name, to_string(value)]

  defp runner_order_args(opts, offset) do
    order =
      case Keyword.get(opts, :runner_order, "alternate") do
        value when value in ["dsex_first", "dsex-first"] ->
          "dsex_first"

        value when value in ["dspy_first", "dspy-first"] ->
          "dspy_first"

        "alternate" ->
          if rem(div(offset, max(Keyword.get(opts, :chunk_size, 100), 1)), 2) == 0,
            do: "dsex_first",
            else: "dspy_first"

        other ->
          Mix.raise(
            "--runner-order must be dsex_first, dspy_first, or alternate, got: #{inspect(other)}"
          )
      end

    ["--runner-order", order]
  end

  defp chunk_plan_summary(chunk_plan) do
    chunk_plan
    |> Enum.map_join(", ", fn chunk ->
      "#{chunk.task}@#{chunk.offset} remaining=#{chunk.remaining}"
    end)
  end

  defp python_args(opts) do
    case Keyword.get(opts, :python) do
      nil -> []
      python -> ["--python", python]
    end
  end

  defp campaign_reports(model, out_dir, campaign_id) do
    out_dir
    |> Path.join("dsex-dspy-parity-#{model_slug(model)}-*.json")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      try do
        case path |> File.read!() |> Jason.decode!() do
          %{"campaign_id" => ^campaign_id} -> true
          _other -> false
        end
      rescue
        _ -> false
      end
    end)
  end

  defp default_campaign_id(model), do: "req_llm-#{model_slug(model)}-#{timestamp_slug()}"

  defp model_slug(model), do: String.replace(model, ~r/[^0-9A-Za-z_.-]/, "_")

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
