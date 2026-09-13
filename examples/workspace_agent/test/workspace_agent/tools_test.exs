defmodule WorkspaceAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias WorkspaceAgent.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "workspace-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "README.md"), "# Example\nA useful project.\n")
    File.write!(Path.join(root, "lib/example.ex"), "defmodule Example do\nend\n")
    File.ln_s!(System.tmp_dir!(), Path.join(root, "outside"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tools: Map.new(Tools.for_workspace(root), &{&1.name, &1})}
  end

  test "lists and reads bounded workspace files", %{tools: tools} do
    listed = Imp.Tool.call(tools.list_files, %{path: "."})
    assert listed =~ "README.md"
    assert listed =~ "lib/example.ex"
    refute listed =~ "outside"

    assert Imp.Tool.call(tools.read_file, %{path: "README.md"}) =~ "A useful project"
  end

  test "reads explicit line ranges and rejects oversized ranges", %{root: root, tools: tools} do
    File.write!(Path.join(root, "long.txt"), Enum.map_join(1..450, "\n", &"line #{&1}"))

    result =
      Imp.Tool.call(tools.read_file, %{path: "long.txt", line_start: 201, line_count: 2})

    assert result == "[long.txt lines 201-202 of 450]\nline 201\nline 202"

    assert {:error, {:schema_validation, [%{field: "line_count", rule: :maximum}]}} =
             Imp.Tool.call(tools.read_file, %{path: "long.txt", line_count: 401})

    assert {:error, {:line_start_beyond_end, 450}} =
             Imp.Tool.call(tools.read_file, %{path: "long.txt", line_start: 451})
  end

  test "rejects lexical and symlink traversal", %{tools: tools} do
    assert {:error, :outside_workspace} =
             Imp.Tool.call(tools.read_file, %{path: "../outside.txt"})

    assert {:error, :outside_workspace} =
             Imp.Tool.call(tools.read_file, %{path: "outside/anything"})
  end

  test "search results carry relative file and line evidence", %{tools: tools} do
    result = Imp.Tool.call(tools.search_text, %{query: "useful", path: "."})
    assert result == "README.md:2:A useful project."

    file_result = Imp.Tool.call(tools.search_text, %{query: "useful", path: "README.md"})
    assert file_result == "README.md:2:A useful project."
  end

  test "creates a new file and replaces only an exact unambiguous fragment", %{
    root: root,
    tools: tools
  } do
    created = Imp.Tool.call(tools.create_file, %{path: "lib/new.ex", content: "old\n"})
    assert created =~ "Created lib/new.ex"
    assert File.read!(Path.join(root, "lib/new.ex")) == "old\n"

    assert {:error, :path_already_exists} =
             Imp.Tool.call(tools.create_file, %{path: "lib/new.ex", content: "clobber"})

    assert File.read!(Path.join(root, "lib/new.ex")) == "old\n"

    updated =
      Imp.Tool.call(tools.replace_text, %{
        path: "lib/new.ex",
        old_text: "old",
        new_text: "new"
      })

    assert updated =~ "Updated lib/new.ex"
    assert File.read!(Path.join(root, "lib/new.ex")) == "new\n"

    File.write!(Path.join(root, "repeated.txt"), "same same")

    assert {:error, {:ambiguous_replacement, 2}} =
             Imp.Tool.call(tools.replace_text, %{
               path: "repeated.txt",
               old_text: "same",
               new_text: "other"
             })
  end

  test "write tools reject traversal", %{tools: tools} do
    assert {:error, :outside_workspace} =
             Imp.Tool.call(tools.create_file, %{path: "../new.txt", content: "no"})

    assert {:error, :outside_workspace} =
             Imp.Tool.call(tools.replace_text, %{
               path: "outside/anything",
               old_text: "a",
               new_text: "b"
             })
  end

  test "runs an argv command in a bounded workspace directory", %{tools: tools} do
    assert result =
             Imp.Tool.call(tools.run_command, %{
               command: "sh",
               args: ["-c", "pwd; printf checked"]
             })

    assert result =~ "exit 0"
    assert result =~ "checked"

    assert {:error, {:command_failed, 7, failed}} =
             Imp.Tool.call(tools.run_command, %{
               command: "sh",
               args: ["-c", "printf failed; exit 7"]
             })

    assert failed =~ "failed"
  end
end
