defmodule Imp.BenchmarkTruth.FileTreeTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.FileTree

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-file-tree-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "inventories regular files in deterministic relative POSIX order", %{root: root} do
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "z.txt"), "last")
    File.write!(Path.join(root, "nested/a.txt"), "first")
    File.write!(Path.join(root, "nested.txt"), "sibling sorts before nested contents")

    inventory = FileTree.inventory!(root)

    assert Enum.map(inventory["files"], & &1["path"]) == [
             "nested.txt",
             "nested/a.txt",
             "z.txt"
           ]

    assert Enum.all?(inventory["files"], &Regex.match?(~r/\A[0-9a-f]{64}\z/, &1["sha256"]))
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, inventory["sha256"])
    assert FileTree.inventory!(Path.relative_to_cwd(root)) == inventory
    assert :ok = FileTree.validate(root, inventory)
  end

  test "validation detects content tampering", %{root: root} do
    path = Path.join(root, "weights.safetensors")
    File.write!(path, "original")
    inventory = FileTree.inventory!(root)

    File.write!(path, "tampered")

    assert {:error,
            %{
              expected_sha256: expected_sha256,
              actual_sha256: actual_sha256
            }} = FileTree.validate(root, inventory)

    assert expected_sha256 == inventory["sha256"]
    refute actual_sha256 == expected_sha256

    assert_raise ArgumentError, ~r/file-tree inventory mismatch/, fn ->
      FileTree.validate!(root, inventory)
    end
  end

  test "records a symlink target and hashes its dereferenced bytes outside the root", %{
    root: root
  } do
    outside = root <> "-blob"
    on_exit(fn -> File.rm(outside) end)
    File.write!(outside, "model bytes")
    link = Path.join(root, "model.safetensors")
    File.ln_s!(outside, link)

    inventory = FileTree.inventory!(root)

    assert [entry] = inventory["files"]
    assert entry["path"] == "model.safetensors"
    assert entry["link_target"] == outside
    assert entry["bytes"] == byte_size("model bytes")

    assert entry["sha256"] ==
             :crypto.hash(:sha256, "model bytes") |> Base.encode16(case: :lower)
  end

  test "rejects broken symlinks", %{root: root} do
    File.ln_s!(Path.join(root, "absent"), Path.join(root, "broken"))

    assert_raise File.Error, ~r/stat symlink target/, fn -> FileTree.inventory!(root) end
  end

  test "rejects special files", %{root: root} do
    fifo = Path.join(root, "events.fifo")

    case System.cmd("mkfifo", [fifo], stderr_to_stdout: true) do
      {_output, 0} ->
        assert_raise ArgumentError, ~r/unsupported file-tree entry.*events\.fifo/, fn ->
          FileTree.inventory!(root)
        end

      {_output, _status} ->
        :ok
    end
  end
end
