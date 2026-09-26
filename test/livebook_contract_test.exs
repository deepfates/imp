defmodule LivebookContractTest do
  @moduledoc """
  Every notebook installs Imp the same way: from the checkout it sits in (or
  `IMP_PATH`), and from Hex when it stands alone. `mix livebook.execute.check`
  runs the notebooks themselves.
  """
  use ExUnit.Case, async: false

  test "every Livebook installs Imp with the same setup" do
    installs =
      for path <- livebooks(), into: %{} do
        {path, install(path)}
      end

    assert installs != %{}

    for {path, install} <- installs do
      assert install =~ "Mix.install([{:imp, path: repo}], install_opts)", path
      assert install =~ ~s(Mix.install([{:imp, "~> ), path
    end

    assert installs |> Map.values() |> Enum.uniq() |> length() == 1,
           "Livebooks install Imp differently: #{inspect(Map.keys(installs))}"
  end

  @tag timeout: 180_000
  test "Livebook setup ignores an unrelated current Mix project" do
    root = File.cwd!()
    notebook = Path.join(root, hd(livebooks()))

    foreign =
      Path.join(
        System.tmp_dir!(),
        "imp-livebook-foreign-cwd-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(foreign)
    File.write!(Path.join(foreign, "mix.exs"), "# deliberately not an Imp project\n")
    on_exit(fn -> File.rm_rf(foreign) end)

    script = ~S'''
    notebook = System.fetch_env!("IMP_LIVEBOOK_CONTRACT_NOTEBOOK")
    body = File.read!(notebook)
    [_, setup | _] = Regex.run(~r/```elixir\n(.*?)\n```/s, body)
    {_value, binding} = Code.eval_string(setup, [], file: notebook)
    IO.puts("resolved_imp_repo=" <> Keyword.fetch!(binding, :repo))
    '''

    {output, status} =
      System.cmd("env", ["-u", "IMP_PATH", "elixir", "-e", script],
        cd: foreign,
        env: [{"IMP_LIVEBOOK_CONTRACT_NOTEBOOK", notebook}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "resolved_imp_repo=#{root}"
    refute output =~ "resolved_imp_repo=#{foreign}"
  end

  defp livebooks, do: Enum.sort(Path.wildcard("livebooks/*.livemd"))

  # The first cell, up to the end of the install.
  defp install(path) do
    [setup | _] =
      Regex.run(~r/```elixir\n(.*?)\n```/s, File.read!(path), capture: :all_but_first)

    case Regex.run(~r/\A.*?Mix\.install\(\[\{:imp, "~> [^"]+"\}\]\)\nend/s, setup) do
      [install] -> install
      nil -> setup
    end
  end
end
