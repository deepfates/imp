defmodule RepositoryHygieneTest do
  use ExUnit.Case, async: true

  @ordinary_git_blob_limit 100_000_000

  test "the release branch contains no ordinary Git blobs too large for GitHub" do
    {output, 0} = System.cmd("git", ["ls-tree", "-lr", "HEAD"], stderr_to_stdout: true)

    oversized =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\d+ blob [0-9a-f]+\s+(\d+)\t(.+)$/, line) do
          [_line, bytes, path] ->
            bytes = String.to_integer(bytes)
            if bytes >= @ordinary_git_blob_limit, do: [{path, bytes}], else: []

          _other ->
            []
        end
      end)

    assert oversized == [],
           "move oversized data to pinned external storage or Git LFS before release: #{inspect(oversized)}"
  end
end
