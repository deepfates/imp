defmodule Mix.Tasks.Dsex.Identity.Assess do
  @moduledoc """
  Run resumable, provider-plural model assessments over identity candidates.

      mix dsex.identity.assess \
        --profile terra=openai_codex:gpt-5.6-terra \
        --profile sonnet=openrouter:anthropic/claude-sonnet-5 \
        --profile flash=openrouter:google/gemini-3.5-flash \
        --env-file .env

      mix dsex.identity.assess --profile pilot=openai_codex:gpt-5.6-terra \
        --limit 24 --batch-size 6 --concurrency 2 --plan

  Outputs are explicitly model assessments, not user research. Credentials are
  resolved by ReqLLM from the environment; this task never hard-codes them.
  Direct Google access may instead use
  `--profile flash=google/gemini:gemini-3.5-flash` with `GOOGLE_API_KEY` or
  `GEMINI_API_KEY`.
  """

  use Mix.Task

  alias DSEx.{BenchmarkEnv, IdentityAssessment}

  @shortdoc "Run resumable model assessments over identity candidates"

  @switches [
    profile: :keep,
    model: :keep,
    env_file: :keep,
    registry: :string,
    enrichments: :keep,
    flags: :keep,
    collisions: :keep,
    atlas: :string,
    out: :string,
    runs_out: :string,
    candidate_id: :keep,
    limit: :integer,
    batch_size: :integer,
    concurrency: :integer,
    timeout: :integer,
    timeout_ms: :integer,
    max_tokens: :integer,
    checkpoint_every: :integer,
    plan: :boolean,
    dry_run: :boolean,
    json: :boolean
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if argv != [], do: Mix.raise("unexpected arguments: #{Enum.join(argv, " ")}")

    opts |> Keyword.get_values(:env_file) |> BenchmarkEnv.load_files!()
    Mix.Task.run("app.start")

    profiles = parse_profiles!(opts)

    run_opts =
      [profiles: profiles]
      |> put_if(:registry, Keyword.get(opts, :registry))
      |> put_paths(:enrichments, Keyword.get_values(opts, :enrichments))
      |> put_paths(:flags, Keyword.get_values(opts, :flags))
      |> put_paths(:collisions, Keyword.get_values(opts, :collisions))
      |> put_if(:atlas, Keyword.get(opts, :atlas))
      |> put_if(:out, Keyword.get(opts, :out))
      |> put_if(:runs_out, Keyword.get(opts, :runs_out))
      |> put_if(:candidate_ids, Keyword.get_values(opts, :candidate_id))
      |> put_if(:limit, Keyword.get(opts, :limit))
      |> put_if(:batch_size, Keyword.get(opts, :batch_size))
      |> put_if(:concurrency, Keyword.get(opts, :concurrency))
      |> put_if(:timeout, timeout(opts))
      |> put_if(:max_tokens, Keyword.get(opts, :max_tokens))
      |> put_if(:checkpoint_every, Keyword.get(opts, :checkpoint_every))
      |> Keyword.put(:dry_run, dry_run?(opts))

    result = IdentityAssessment.run_files!(run_opts)
    print_result(result, Keyword.get(opts, :json, false))

    if get_in(result, ["summary", "failed_batches"]) not in [nil, 0] do
      Mix.raise(
        "#{result["summary"]["failed_batches"]} identity assessment batches failed; " <>
          "failure records were checkpointed and will be retried on the next run"
      )
    end
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp parse_profiles!(opts) do
    specs = Keyword.get_values(opts, :profile) ++ Keyword.get_values(opts, :model)

    if specs == [] do
      Mix.raise("provide at least one --profile NAME=PROVIDER:MODEL or --model PROVIDER:MODEL")
    end

    Enum.map(specs, &parse_profile!/1)
  end

  defp parse_profile!(spec) do
    case String.split(spec, "=", parts: 2) do
      [id, model] when id != "" and model != "" ->
        %{id: id, name: id, model: model}

      [model] when model != "" ->
        id = profile_id(model)
        %{id: id, name: id, model: model}

      _ ->
        Mix.raise("invalid profile #{inspect(spec)}; expected NAME=PROVIDER:MODEL")
    end
  end

  defp profile_id(model) do
    model
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp timeout(opts) do
    Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout)
  end

  defp dry_run?(opts) do
    Keyword.get(opts, :plan, false) or Keyword.get(opts, :dry_run, false)
  end

  defp print_result(result, true) do
    Mix.shell().info(Jason.encode!(result, pretty: true))
  end

  defp print_result(result, false) do
    summary = result["summary"]
    Mix.shell().info("identity assessment mode: #{result["mode"]}")
    Mix.shell().info("candidate entities: #{summary["candidate_entities"]}")
    Mix.shell().info("assessor profiles: #{summary["profiles"]}")

    Mix.shell().info(
      "records: #{summary["existing_complete_records"]} resumed, " <>
        "#{summary["succeeded_records"]} new, #{summary["failed_records"]} failed, " <>
        "#{summary["pending_records"]} planned"
    )

    Mix.shell().info(
      "batches: #{summary["planned_batches"]} planned, " <>
        "#{summary["attempted_batches"]} attempted"
    )
  end

  defp put_paths(opts, _key, []), do: opts
  defp put_paths(opts, key, paths), do: Keyword.put(opts, key, paths)

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, _key, []), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
