defmodule LivebookContractTest do
  @moduledoc """
  Every notebook's first cell installs Imp, from the checkout `IMP_PATH` names
  when it is set and from Hex otherwise. `mix livebook.execute.check` sets
  `IMP_PATH` to this checkout and runs the notebooks themselves.
  """
  use ExUnit.Case, async: false

  test "every Livebook installs Imp with the same first cell" do
    installs =
      for path <- livebooks(), into: %{} do
        {path, install(path)}
      end

    assert installs != %{}

    for {path, install} <- installs do
      assert install =~ ~s[System.get_env("IMP_PATH")], path
      assert install =~ "Mix.install([{:imp, path: imp_path}]", path
      assert install =~ ~s(Mix.install([{:imp, "~> ), path
    end

    assert installs |> Map.values() |> Enum.uniq() |> length() == 1,
           "Livebooks install Imp differently: #{inspect(Map.keys(installs))}"
  end

  test "every Livebook has only its title and one cell before its first section" do
    # Livebook imports the cells before the first `##` heading as the setup
    # cell only when there is exactly one cell and no other text there;
    # otherwise it makes an unnamed section and leaves the setup cell empty.
    for path <- livebooks() do
      [preamble | _] = Regex.split(~r/^## /m, File.read!(path), parts: 2)

      assert Regex.match?(~r/\A# [^\n]+\s+```elixir\n(?:(?!```).)*\n```\s*\z/s, preamble),
             "#{path} must have only its title and one elixir cell before its first section"
    end
  end

  @tag timeout: 180_000
  test "with IMP_PATH set, the first cell installs that checkout from any directory" do
    root = File.cwd!()
    notebook = Path.join(root, hd(livebooks()))

    elsewhere =
      Path.join(System.tmp_dir!(), "imp-livebook-cwd-#{System.unique_integer([:positive])}")

    File.mkdir_p!(elsewhere)
    File.write!(Path.join(elsewhere, "mix.exs"), "# deliberately not an Imp project\n")
    on_exit(fn -> File.rm_rf(elsewhere) end)

    script = ~S'''
    notebook = System.fetch_env!("IMP_LIVEBOOK_CONTRACT_NOTEBOOK")
    [_, install | _] = Regex.run(~r/```elixir\n(.*?)\n```/s, File.read!(notebook))
    Code.eval_string(install, [], file: notebook)
    IO.puts("imp_source=" <> List.to_string(Imp.module_info(:compile)[:source]))
    '''

    {output, status} =
      System.cmd("elixir", ["-e", script],
        cd: elsewhere,
        env: [{"IMP_PATH", root}, {"IMP_LIVEBOOK_CONTRACT_NOTEBOOK", notebook}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "imp_source=#{Path.join(root, "lib/imp.ex")}"
  end

  defp livebooks, do: Enum.sort(Path.wildcard("livebooks/*.livemd"))

  defp install(path) do
    [install | _] =
      Regex.run(~r/```elixir\n(.*?)\n```/s, File.read!(path), capture: :all_but_first)

    install
  end
end
