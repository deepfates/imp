defmodule MatchedInstructionOptimizersTREC.SourceIdentity do
  @moduledoc false

  def capture_clean!(repo_root, pinned) when is_binary(repo_root) and is_map(pinned) do
    repo_root = Path.expand(repo_root)
    top_level = git!(repo_root, ~w(rev-parse --show-toplevel))

    unless same_file?(top_level, repo_root),
      do: raise("source root is not its own Git checkout: #{repo_root}")

    case git!(repo_root, ~w(status --porcelain --untracked-files=all)) do
      "" -> Map.put(pinned, "imp", git!(repo_root, ~w(rev-parse HEAD)))
      changed -> raise "Imp launch tree is not clean:\n#{changed}"
    end
  end

  def current(repo_root, pinned) when is_binary(repo_root) and is_map(pinned) do
    Map.put(pinned, "imp", git!(Path.expand(repo_root), ~w(rev-parse HEAD)))
  end

  defp git!(repo_root, args) do
    case System.cmd("git", ["-C", repo_root | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp same_file?(left, right) do
    left = File.stat!(left)
    right = File.stat!(right)
    left.inode == right.inode and left.major_device == right.major_device
  end
end
