#!/usr/bin/env elixir

upstream = System.get_env("DSPY_UPSTREAM") || "/tmp/dspy-upstream"
root = Path.expand(Path.join(upstream, "dspy"))

unless File.dir?(root) do
  Mix.raise("DSPy upstream checkout not found at #{root}. Set DSPY_UPSTREAM=/path/to/dspy.")
end

packages = [
  {"root", "__init__.py"},
  {"adapters", "adapters/__init__.py"},
  {"clients", "clients/__init__.py"},
  {"datasets", "datasets/__init__.py"},
  {"evaluate", "evaluate/__init__.py"},
  {"predict", "predict/__init__.py"},
  {"primitives", "primitives/__init__.py"},
  {"retrievers", "retrievers/__init__.py"},
  {"signatures", "signatures/__init__.py"},
  {"streaming", "streaming/__init__.py"},
  {"teleprompt", "teleprompt/__init__.py"}
]

extract = fn source ->
  all_match = Regex.run(~r/__all__\s*=\s*\[(.*?)\]/s, source)

  exports =
    case all_match do
      [_all, body] ->
        Regex.scan(~r/["']([^"']+)["']/, body)
        |> Enum.map(fn [_match, name] -> name end)

      nil ->
        Regex.scan(~r/^(?:from|import)\s+[^\n()]+?\s+import\s+([^\n()#]+)$/m, source)
        |> Enum.flat_map(fn [_line, names] ->
          names
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "*")))
        end)
    end

  exports
  |> Enum.map(&String.replace(&1, ~r/\s+as\s+.*/, ""))
  |> Enum.reject(&String.starts_with?(&1, "_"))
  |> Enum.uniq()
  |> Enum.sort()
end

data =
  packages
  |> Enum.map(fn {package, relative} ->
    path = Path.join(root, relative)
    {package, extract.(File.read!(path))}
  end)
  |> Map.new()

File.mkdir_p!("priv/parity")
File.write!("priv/parity/upstream_public_exports.json", Jason.encode!(data, pretty: true))

IO.puts("Wrote priv/parity/upstream_public_exports.json with #{Enum.sum(Enum.map(data, fn {_k, v} -> length(v) end))} exports.")
