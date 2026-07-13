defmodule Mix.Tasks.Dsex.Identity.Collisions do
  @moduledoc """
  Check derived package forms against exact public registry endpoints.

      mix dsex.identity.collisions
      mix dsex.identity.collisions --source hex --source npm,pypi --delay-ms 500
      mix dsex.identity.collisions --source all --refresh
  """

  use Mix.Task

  alias DSEx.IdentityCollision

  @shortdoc "Check identity candidates for exact package registry collisions"

  @switches [
    enrichments: :string,
    source: :keep,
    delay_ms: :integer,
    checks_out: :string,
    flags_out: :string,
    checked_at: :string,
    refresh: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if argv != [], do: Mix.raise("unexpected arguments: #{Enum.join(argv, " ")}")

    sources = parse_sources(Keyword.get_values(opts, :source))
    delay_ms = Keyword.get(opts, :delay_ms, IdentityCollision.default_delay_ms())

    run_opts =
      [
        enrichments: Keyword.get(opts, :enrichments, "identity/enrichments.jsonl"),
        sources: sources,
        delay_ms: delay_ms,
        checks_out: Keyword.get(opts, :checks_out, IdentityCollision.default_checks_out()),
        flags_out: Keyword.get(opts, :flags_out, IdentityCollision.default_flags_out()),
        refresh: Keyword.get(opts, :refresh, false)
      ]
      |> maybe_put(:checked_at, Keyword.get(opts, :checked_at))

    result =
      try do
        IdentityCollision.run_files!(run_opts)
      rescue
        error in [ArgumentError] -> Mix.raise(Exception.message(error))
      end

    print_summary(result.stats)
  end

  defp parse_sources(values) do
    values
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> IdentityCollision.normalize_sources!()
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp print_summary(stats) do
    Mix.shell().info(
      "identity package checks: #{stats.total} current, #{stats.new_checks} new, " <>
        "#{stats.resumed_checks} resumed, #{stats.network_attempts} HTTP attempts"
    )

    status_summary =
      stats.by_status
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(", ", fn {status, count} -> "#{status}=#{count}" end)

    Mix.shell().info("status totals: #{status_summary}")

    Enum.each(stats.sources, fn source ->
      counts = Map.fetch!(stats.by_source, source)

      source_summary =
        counts
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join(", ", fn {status, count} -> "#{status}=#{count}" end)

      Mix.shell().info("#{source}: #{source_summary}")
    end)

    Mix.shell().info("collision flags added: #{stats.flags_added}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
