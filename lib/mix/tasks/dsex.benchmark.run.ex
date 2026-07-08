defmodule Mix.Tasks.Dsex.Benchmark.Run do
  @moduledoc """
  Run benchmark truth evaluation over canonical JSONL files.

      mix dsex.benchmark.run --gsm8k benchmarks/data/gsm8k-test-0-20.jsonl \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-20.jsonl --max-examples 20
      mix dsex.benchmark.run --colors benchmarks/data/colors-test-0-6.jsonl
      mix dsex.benchmark.run --ifbench-instruction-following benchmarks/data/ifbench_instruction_following-test-0-3.jsonl \\
        --hard-math benchmarks/data/hard_math-test-0-3.jsonl

  By default this runs in fixture mode. Use `--live` to use the ReqLLM-backed
  OpenAI provider from `OPENAI_API_KEY`/`OPENAI_MODEL`.
  """

  use Mix.Task

  @shortdoc "Run DSEx benchmark truth evaluations"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          gsm8k: :string,
          hotpotqa: :string,
          colors: :string,
          iris: :string,
          iris_typo: :string,
          heart_disease: :string,
          retrieval_qa: :string,
          claim_verification: :string,
          composition_orchestration: :string,
          ifbench_instruction_following: :string,
          hard_math: :string,
          offset: :integer,
          max_examples: :integer,
          max_concurrency: :integer,
          out: :string,
          live: :boolean,
          model: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    tasks = tasks(opts)

    if tasks == [] do
      Mix.raise(
        "provide at least one dataset path with --gsm8k, --hotpotqa, --colors, --iris-typo, --heart-disease, --retrieval-qa, --claim-verification, --composition-orchestration, --ifbench-instruction-following, or --hard-math"
      )
    end

    mode = if Keyword.get(opts, :live, false), do: :live, else: :fixture

    result =
      DSEx.BenchmarkTruth.run(
        tasks: tasks,
        mode: mode,
        lm: live_lm(mode, opts),
        model: model_metadata(mode, opts),
        out_dir: Keyword.get(opts, :out, "benchmarks/results"),
        offset: Keyword.get(opts, :offset, 0),
        max_examples: Keyword.get(opts, :max_examples, 20),
        max_concurrency: Keyword.get(opts, :max_concurrency, 1)
      )

    Mix.shell().info("benchmark truth report: #{result.out_path}")
    Mix.shell().info("aggregate score: #{result.report["aggregate_score"]}")
  end

  defp tasks(opts) do
    []
    |> maybe_put(:gsm8k, Keyword.get(opts, :gsm8k))
    |> maybe_put(:hotpotqa, Keyword.get(opts, :hotpotqa))
    |> maybe_put(:colors, Keyword.get(opts, :colors))
    |> maybe_put(:iris, Keyword.get(opts, :iris))
    |> maybe_put(:iris_typo, Keyword.get(opts, :iris_typo))
    |> maybe_put(:heart_disease, Keyword.get(opts, :heart_disease))
    |> maybe_put(:retrieval_qa, Keyword.get(opts, :retrieval_qa))
    |> maybe_put(:claim_verification, Keyword.get(opts, :claim_verification))
    |> maybe_put(:composition_orchestration, Keyword.get(opts, :composition_orchestration))
    |> maybe_put(
      :ifbench_instruction_following,
      Keyword.get(opts, :ifbench_instruction_following)
    )
    |> maybe_put(:hard_math, Keyword.get(opts, :hard_math))
  end

  defp maybe_put(tasks, _task, nil), do: tasks
  defp maybe_put(tasks, task, path), do: [{task, path} | tasks] |> Enum.reverse()

  defp live_lm(:fixture, _opts), do: nil

  defp live_lm(:live, opts) do
    api_key =
      System.get_env("OPENAI_API_KEY") || Mix.raise("OPENAI_API_KEY is required for --live")

    model = live_model(opts)
    DSEx.req_llm("openai:#{model}", api_key: api_key)
  end

  defp model_metadata(:fixture, _opts), do: %{provider: "fixture", model: "oracle"}

  defp model_metadata(:live, opts) do
    %{
      provider: "req_llm",
      model: live_model(opts)
    }
  end

  defp live_model(opts) do
    Keyword.get(opts, :model) ||
      System.get_env("OPENAI_MODEL") ||
      Mix.raise("OPENAI_MODEL or --model is required for --live")
  end
end
