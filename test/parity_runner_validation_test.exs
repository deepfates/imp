defmodule Mix.Tasks.Imp.Benchmark.ParityValidationTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Imp.Benchmark.Parity

  test "validates a missing imp-first Python executable before provider setup" do
    missing = Path.join(tmp_dir(), "missing-python")

    assert_raise Mix.Error, ~r/--python must name an executable.*missing-python/, fn ->
      Parity.run([
        "--runner-order",
        "imp_first",
        "--python",
        missing,
        "--gsm8k",
        "unused.jsonl"
      ])
    end
  end

  test "resolves executable absolute and relative paths" do
    root = tmp_dir()
    path = Path.join(root, "bin/python")
    make_executable(path)

    assert Parity.python_executable!(python: path) == path

    assert File.cd!(root, fn ->
             Parity.python_executable!(python: "./bin/python") == Path.expand("./bin/python")
           end) == true
  end

  test "resolves executable command names through PATH" do
    root = tmp_dir()
    path = Path.join(root, "parity-python")
    make_executable(path)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", root)

    on_exit(fn -> restore_env("PATH", previous_path) end)

    assert Parity.python_executable!(python: "parity-python") == path
  end

  test "rejects a non-executable path" do
    path = Path.join(tmp_dir(), "python")
    File.write!(path, "not executable")

    assert_raise Mix.Error, ~r/--python must name an executable/, fn ->
      Parity.python_executable!(python: path)
    end
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "imp-parity-validation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp make_executable(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
