#!/usr/bin/env elixir

snapshot = "priv/parity/upstream_public_exports.json"
matrix = "PARITY.md"

unless File.exists?(snapshot), do: Mix.raise("#{snapshot} is missing. Run mix parity.generate.")
unless File.exists?(matrix), do: Mix.raise("#{matrix} is missing.")

exports = snapshot |> File.read!() |> Jason.decode!()
matrix_text = File.read!(matrix)

missing =
  exports
  |> Enum.flat_map(fn {package, names} ->
    Enum.map(names, fn name -> {package, name} end)
  end)
  |> Enum.reject(fn {_package, name} ->
    matrix_text =~ "`#{name}`" or matrix_text =~ "`#{name |> Macro.camelize()}`"
  end)

if missing != [] do
  details =
    missing
    |> Enum.map(fn {package, name} -> "- #{package}: #{name}" end)
    |> Enum.join("\n")

  Mix.raise("PARITY.md does not classify all upstream public exports:\n#{details}")
end

if matrix_text =~ "TODO" or matrix_text =~ "unclassified" or matrix_text =~ "missing" do
  Mix.raise("PARITY.md contains TODO/unclassified/missing language.")
end

IO.puts("Parity export check passed.")
