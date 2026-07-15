case Imp.LegacyIdentityAudit.run() do
  :ok ->
    {:ok, report} = Imp.LegacyIdentityAudit.audit()
    files = report.findings |> Enum.map(& &1.path) |> Enum.uniq() |> length()

    IO.puts(
      "legacy identity audit passed: #{length(report.findings)} matches in #{files} allowlisted files"
    )

  {:error, %{violations: violations}} ->
    Enum.each(violations, fn finding ->
      IO.puts(:stderr, "#{finding.path}:#{finding.line}:#{finding.text}")
    end)

    System.halt(1)

  {:error, reason} ->
    IO.puts(:stderr, "legacy identity audit could not run: #{inspect(reason)}")
    System.halt(1)
end
