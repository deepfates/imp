defmodule Mix.Tasks.Imp.Identity.Progress do
  @moduledoc """
  Show the accepted, pending, and planned identity frontier and downstream coverage.

      mix imp.identity.progress
      mix imp.identity.progress --json
      mix imp.identity.progress --out identity/reports/progress.json
  """

  use Mix.Task

  @shortdoc "Show the live Step 8 identity census frontier"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          root: :string,
          atlas: :string,
          workflow: :string,
          inbox: :string,
          registry: :string,
          enrichments: :string,
          assessments: :string,
          collision_checks: :string,
          flags: :string,
          dissent: :string,
          out: :string,
          json: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    report = Imp.IdentityProgress.snapshot(opts)

    if out = opts[:out] do
      root = Keyword.get(opts, :root, File.cwd!())
      path = Path.expand(out, root)
      Imp.IdentityCheckpoint.write_atomic!(path, Jason.encode!(report, pretty: true) <> "\n")
    end

    output =
      if opts[:json],
        do: Jason.encode!(report, pretty: true) <> "\n",
        else: Imp.IdentityProgress.render_text(report)

    Mix.shell().info(output)
  end
end
