#!/usr/bin/env elixir

audit = "PRODUCTION_AUDIT.md"
unless File.exists?(audit), do: Mix.raise("#{audit} is missing")

text = File.read!(audit)

rows =
  text
  |> String.split("\n")
  |> Enum.filter(&String.starts_with?(&1, "| "))
  |> Enum.reject(&String.contains?(&1, "---"))
  |> Enum.reject(&String.contains?(&1, " ID "))

bad_rows =
  rows
  |> Enum.filter(fn row ->
    columns = row |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

    case columns do
      [_id, priority, _requirement, status | _] when priority in ["P0", "P1"] ->
        status not in ["PROVEN", "PARTIAL", "UNPROVEN"]

      _ ->
        false
    end
  end)

if bad_rows != [] do
  Mix.raise("Production audit has malformed rows:\n" <> Enum.join(bad_rows, "\n"))
end

unproven =
  rows
  |> Enum.filter(fn row ->
    columns = row |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

    case columns do
      [_id, priority, _requirement, status | _] when priority in ["P0", "P1"] ->
        status != "PROVEN"

      _ ->
        false
    end
  end)

File.write!("priv/parity/production_audit_unproven.json", Jason.encode!(%{unproven_count: length(unproven), rows: unproven}, pretty: true))

if unproven == [] do
  IO.puts("Production audit passed; 0 P0/P1 rows remain unproven.")
else
  Mix.raise("Production audit has #{length(unproven)} unproven P0/P1 rows.")
end
