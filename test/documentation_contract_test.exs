defmodule DocumentationContractTest do
  @moduledoc """
  Properties every rendered page holds. The pages are the `extras` in
  `mix.exs`, so a page is checked by being added to the docs.

  Code blocks on a page run in order, sharing one binding, in a scratch
  directory. The Getting started pages are one walk-through and share one
  binding across pages:

    * Every Elixir block must parse.
    * Blocks run with the network refused: provider keys in the environment
      are replaced by a placeholder, and every HTTP request gets a 401 and is
      counted. Building a provider client works; a block that sends a request
      is live, so its results are not checked, and what it binds (variables,
      modules) is live from then on. A block naming one of `@live_markers`
      starts other processes or installs packages, so it is live without
      running.
    * A block that needs a live variable is skipped the same way. A block that
      needs a variable no earlier block defined is a fragment and is only
      parsed, unless it shows a result.
    * `#=> value` after an expression is a claim about that expression's
      value, and is checked. The value is read as a pattern (so a map may
      show some of its keys), then as an expression, then compared with
      `inspect/1`. Lines beginning `#` and three spaces continue it.
    * A block fenced with `~~~` is only parsed.

  Only guides run here. Livebooks run as notebooks under
  `mix livebook.execute.check`; a cheatsheet is a set of separate snippets,
  not a sequence; the release notes and changelog are history.
  """
  use ExUnit.Case, async: false

  # Words that belong to the project's research and process, not to a reader
  # building with Imp. Checked in prose only; code may use them (an `owner:`
  # option is fine).
  @banned_vocabulary [
    ~r/\breceipts?\b/i,
    ~r/\blanes?\b/i,
    ~r/\bgat(?:e|es|ed|ing)\b/i,
    ~r/\btreatments?\b/i,
    ~r/\bpre-?registered\b/i,
    ~r/\bfalsif(?:y|ies|ied|ying|iable|ication)\b/i,
    ~r/\bC[0-5]\b/,
    ~r/\bparity claims?\b/i,
    ~r/\bowners?\b/i,
    ~r/\brulings?\b/i,
    ~r/\bconstellation\b/i,
    ~r/\bworkshop\b/i,
    ~r/\b(?:Dwell|Kite|Haven)\b/,
    ~r/\bevidence\b/i,
    ~r/\bfidelity\b/i,
    ~r/\b(?:imp|de|dee|eid)-[a-z0-9]{4}\b/
  ]

  # A block naming one of these starts servers, other OS processes or a
  # package install, so the doc tests parse it and do not run it.
  @live_markers [
    "Imp.MCP.connect",
    "Mix.install"
  ]

  # Replaced for the run, so no real key is ever sent anywhere.
  @provider_keys ["OPENAI_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY"]

  # Names the module check reads as modules that are not documented modules:
  # process names and namespaces.
  @module_reference_allowlist MapSet.new([
                                "Imp.Optimize",
                                "Imp.Optimizer",
                                "Imp.TaskSupervisor",
                                "Imp.UnlinkedTaskSupervisor"
                              ])

  @history ["CHANGELOG.md", "RELEASE_NOTES.md"]

  describe "every rendered page" do
    test "has Elixir blocks that parse" do
      failures =
        for page <- pages(),
            %{lang: "elixir"} = block <- blocks(page),
            {:error, reason} <- [parse(block.code)],
            do: "#{page}:#{block.line}: #{reason}"

      assert failures == [], Enum.join(failures, "\n")
    end

    @tag timeout: 600_000
    test "runs its provider-free blocks and matches the results it shows" do
      failures =
        for session <- sessions(),
            blocks = Enum.map(session, &{&1, blocks(&1)}),
            failure <- in_scratch_dir(fn -> run_session(blocks) end).failures,
            do: failure

      assert failures == [], Enum.join(failures, "\n\n")
    end

    test "links only to files that exist and render" do
      extras = MapSet.new(pages())
      by_name = pages() |> Enum.group_by(&Path.basename/1)

      failures =
        for page <- pages(),
            {target, line} <- relative_links(page),
            failure = link_failure(page, target, extras, by_name),
            failure != nil,
            do: "#{page}:#{line}: #{target} #{failure}"

      assert failures == [], Enum.join(failures, "\n")
    end

    # ExDoc's Markdown parser reads a fence whose info string has a second
    # word (```elixir no_run) as inline code, which unbalances every fence
    # after it: the rest of the page renders its headings as literal text.
    test "fences code with a one-word info string" do
      failures =
        for page <- pages(),
            {line, number} <- page |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(~r/^\s*(```|~~~)\S+\s+\S/, line),
            do: "#{page}:#{number}"

      assert failures == [], "fences with a multi-word info string: #{inspect(failures)}"
    end

    test "names only documented modules" do
      documented = documented_modules()

      failures =
        for page <- pages(),
            page not in @history,
            name <- page |> File.read!() |> module_references(),
            not MapSet.member?(@module_reference_allowlist, name),
            not MapSet.member?(documented, name),
            uniq: true,
            do: "#{page}: #{name}"

      assert failures == [], Enum.join(failures, "\n")
    end

    test "keeps research and process vocabulary out of its prose" do
      failures =
        for page <- pages(),
            page not in @history,
            {line, number} <- page |> File.read!() |> prose() |> Enum.with_index(1),
            pattern <- @banned_vocabulary,
            [word | _] <- [Regex.run(pattern, line)],
            do: "#{page}:#{number}: #{word}"

      assert failures == [], Enum.join(failures, "\n")
    end
  end

  describe "the research material" do
    test "links only to files that exist" do
      failures =
        for page <- research_pages(),
            {target, line} <- relative_links(page),
            not File.exists?(resolve(page, target)),
            do: "#{page}:#{line}: #{target}"

      assert failures == [], Enum.join(failures, "\n")
    end

    # The file name of a Mix task module is not the task name: both
    # lib/mix/tasks/imp.benchmark.classical_optimizer_differential.ex and
    # lib/mix/tasks/imp.benchmark.weight_composition_differential.ex define a
    # module with no run/1 plus several sibling task modules that do have one.
    # Resolving the module is therefore not enough; it has to be invocable.
    test "publishes only mix commands that can be invoked" do
      published =
        for page <- research_pages(),
            [_, task] <- Regex.scan(~r/mix ([a-z][a-z_0-9.]*[a-z0-9])/, File.read!(page)),
            task not in ["deps.get", "run", "test", "help", "compile", "format"],
            uniq: true,
            do: {page, task}

      assert length(published) > 20

      failures =
        for {page, task} <- published,
            not invocable_mix_command?(task),
            do: "#{page}: mix #{task}"

      assert failures == [], Enum.join(failures, "\n")
    end
  end

  describe "the checks themselves" do
    test "a shown result that does not match fails" do
      assert [_] = run_markdown("```elixir\n1 + 1\n#=> 3\n```\n").failures
      assert [] == run_markdown("```elixir\n1 + 1\n#=> 2\n```\n").failures
    end

    test "each shown result in a block is checked against its own expression" do
      page = """
      ```elixir
      x = 2
      x * 3
      #=> 6
      x + 1
      #=> 4
      ```
      """

      assert %{failures: [_], checked: 1} = run_markdown(page)
    end

    test "a shown map is a pattern, and a multi-line result continues with #   " do
      page = """
      ```elixir
      %{team: "atlas", score: 1.0, extra: [1, 2]}
      #=> %{team: "atlas",
      #     score: 1.0}
      ```
      """

      assert %{failures: [], checked: 1} = run_markdown(page)
    end

    test "a block that sends a request is live, and so is what depends on it" do
      page = """
      ```elixir
      lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))
      router = Imp.predict("ticket -> team", lm: lm)
      ```

      ```elixir
      {:ok, prediction} = Imp.call(router, %{ticket: "charged twice"})
      Imp.get(prediction, :team)
      #=> :never_checked
      ```

      ```elixir
      prediction.metadata
      #=> :never_checked
      ```
      """

      assert %{failures: [], checked: 0, ran: 1, requests: 1} = run_markdown(page)
    end

    test "a real provider key is never visible to a page" do
      page = """
      ```elixir
      System.fetch_env!("OPENAI_API_KEY")
      #=> "sk-the-doc-tests-send-no-requests"
      ```
      """

      assert %{failures: [], checked: 1} = run_markdown(page)
    end

    test "blocks share one binding, in order" do
      page = """
      ```elixir
      router = Imp.predict("ticket -> team", lm: Imp.LM.Static.new(handler: fn _, _ -> %{team: "atlas"} end))
      ```

      ```elixir
      {:ok, prediction} = Imp.call(router, %{ticket: "charged twice"})
      Imp.get(prediction, :team)
      #=> "atlas"
      ```
      """

      assert %{failures: [], checked: 1, ran: 2} = run_markdown(page)
    end

    test "a fragment is parsed only, unless it shows a result" do
      assert %{failures: [], ran: 0} = run_markdown("```elixir\nImp.call(program, inputs)\n```\n")

      assert %{failures: [_]} =
               run_markdown("```elixir\nImp.call(program, inputs)\n#=> {:ok, _}\n```\n")
    end

    test "a provider-free block that raises fails, unless it is fenced with ~~~" do
      assert %{failures: [_]} = run_markdown("```elixir\nraise \"boom\"\n```\n")
      assert %{failures: []} = run_markdown("~~~elixir\nraise \"boom\"\n~~~\n")
    end

    test "prose excludes code, links and comments" do
      text = """
      A gate in prose.
      `gate` in code, [a link](https://example.com/gate), <!-- a gate -->
      ```elixir
      gate = 1
      ```
      """

      assert ["A gate in prose." | rest] = prose(text)
      refute Enum.any?(rest, &(&1 =~ "gate"))
    end

    test "the invocable-command check rejects a module that is not a runnable task" do
      refute invocable_mix_command?("imp.benchmark.classical_optimizer_differential")
      refute invocable_mix_command?("imp.benchmark.weight_composition_differential")
      refute invocable_mix_command?("imp.benchmark.no_such_task_at_all")

      assert invocable_mix_command?("imp.benchmark.bootstrap_few_shot_differential")
      assert invocable_mix_command?("differential.check")
    end
  end

  describe "Getting started" do
    test "chains its pages in reading order with Next links" do
      [_ | rest] = pages = getting_started()

      for {page, next} <- Enum.zip(pages, rest) do
        assert File.read!(page) =~
                 ~r/\*\*Next:\*\* \[[^\]]*\]\(#{Regex.escape(Path.basename(next))}\)/,
               "#{page} does not end with a Next link to #{next}"
      end
    end
  end

  # Runs every block, live ones included, against a provider: README on its
  # own, Getting started as one session, and each other guide on its own.
  # The pages show OpenAI; with only OPENROUTER_API_KEY set, the same models
  # run through OpenRouter's OpenAI route.
  @tag :live
  @tag timeout: 1_200_000
  test "every guide runs end to end against a provider" do
    for session <- sessions() do
      blocks =
        for page <- session,
            block <- blocks(page),
            block.lang == "elixir" and block.fence == "```",
            do: {page, block}

      in_scratch_dir(fn ->
        Enum.reduce(blocks, [], fn {page, block}, binding ->
          {_result, binding} =
            Code.eval_string(provider(block.code), binding, file: page, line: block.line)

          binding
        end)
      end)
    end
  end

  defp provider(code) do
    if System.get_env("OPENAI_API_KEY") || is_nil(System.get_env("OPENROUTER_API_KEY")) do
      code
    else
      code
      |> String.replace(~s|Imp.req_llm("openai:|, ~s|Imp.req_llm("openrouter:openai/|)
      |> String.replace(
        ~s|System.fetch_env!("OPENAI_API_KEY")|,
        ~s|System.fetch_env!("OPENROUTER_API_KEY")|
      )
    end
  end

  ## Pages

  defp pages do
    Mix.Project.config()
    |> Keyword.fetch!(:docs)
    |> Keyword.fetch!(:extras)
    |> Enum.map(fn
      {path, _opts} -> to_string(path)
      path -> path
    end)
  end

  # Getting started is one walk-through, read as one session; every other
  # guide stands alone.
  defp sessions do
    gs = getting_started()
    [gs | for(page <- pages(), guide?(page), page not in gs, do: [page])]
  end

  defp getting_started do
    Mix.Project.config()
    |> Keyword.fetch!(:docs)
    |> Keyword.fetch!(:groups_for_extras)
    |> Keyword.fetch!(:"Getting started")
  end

  defp guide?(page), do: String.ends_with?(page, ".md") and page not in @history

  defp research_pages, do: Path.wildcard("research/**/*.md")

  defp documented_modules do
    "priv/public_api.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("modules")
    |> MapSet.new(& &1["module"])
  end

  defp module_references(text) do
    ~r/(?<![\w.])Imp(?:\.[A-Z][A-Za-z0-9_]*)+/
    |> Regex.scan(text)
    |> List.flatten()
  end

  ## Blocks

  # Splits Markdown into fenced blocks: %{fence, lang, code, line}.
  defp blocks(page), do: page |> File.read!() |> parse_blocks()

  defp parse_blocks(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn
      {line, number}, {acc, nil} ->
        case Regex.run(~r/^\s*(```|~~~)\s*([\w+-]*)\s*$/, line) do
          [_, fence, lang] -> {acc, %{fence: fence, lang: lang, lines: [], line: number + 1}}
          nil -> {acc, nil}
        end

      {line, _number}, {acc, open} ->
        if String.trim(line) == open.fence do
          block = %{
            fence: open.fence,
            lang: open.lang,
            line: open.line,
            code: open.lines |> Enum.reverse() |> Enum.join("\n")
          }

          {[block | acc], nil}
        else
          {acc, %{open | lines: [line | open.lines]}}
        end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, _} -> :ok
      {:error, {meta, message, token}} -> {:error, "line #{meta[:line]}: #{message}#{token}"}
    end
  end

  ## Running a page

  defp run_markdown(text), do: run_session([{"page.md", parse_blocks(text)}])

  # Pages in a session share one binding, in order.
  defp run_session(pages) do
    without_network(fn requests ->
      state = %{
        binding: [],
        live_vars: MapSet.new(),
        live_modules: [],
        failures: [],
        ran: 0,
        checked: 0,
        requests: requests
      }

      pages
      |> Enum.reduce(state, fn {page, blocks}, state ->
        blocks
        |> Enum.filter(&(&1.lang == "elixir" and &1.fence == "```"))
        |> Enum.reduce(state, &run_block(page, &1, &2))
      end)
      |> Map.update!(:failures, &Enum.reverse/1)
      |> Map.put(:requests, :counters.get(requests, 1))
    end)
  end

  # Every request Req makes (ReqLLM builds its requests with Req) gets a 401,
  # which is not retried, and is counted.
  defp without_network(fun) do
    requests = :counters.new(1, [:atomics])
    defaults = Req.default_options()
    keys = Map.new(@provider_keys, &{&1, System.get_env(&1)})

    refuse = fn request ->
      :counters.add(requests, 1, 1)
      body = %{"error" => %{"message" => "the doc tests send no requests"}}
      {request, Req.Response.new(status: 401, body: body)}
    end

    try do
      Enum.each(@provider_keys, &System.put_env(&1, "sk-the-doc-tests-send-no-requests"))
      Req.default_options(Keyword.put(defaults, :adapter, refuse))
      fun.(requests)
    after
      Req.default_options(defaults)

      Enum.each(keys, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp run_block(page, block, state) do
    where = "#{page}:#{block.line}"
    segments = segments(block.code)

    cond do
      parse(block.code) != :ok ->
        state

      Enum.any?(@live_markers, &String.contains?(block.code, &1)) ->
        taint(state, block.code)

      true ->
        Enum.reduce_while(segments, %{state | ran: state.ran + 1}, fn segment, state ->
          case run_segment(segment, state) do
            {:ok, state} ->
              {:cont, state}

            {:skip, :live} ->
              {:halt, taint(%{state | ran: state.ran - 1}, block.code)}

            {:skip, :fragment} ->
              if Enum.any?(segments, & &1.expected) do
                {:halt, fail(state, where, "needs a variable no earlier block defines")}
              else
                {:halt, taint(%{state | ran: state.ran - 1}, block.code)}
              end

            # What a failed block would have bound is missing; its dependents
            # are skipped rather than reported again.
            {:error, message} ->
              {:halt, state |> fail(where, message) |> taint(block.code)}
          end
        end)
    end
  end

  defp fail(state, where, message),
    do: %{state | failures: ["#{where}: #{message}" | state.failures]}

  defp taint(state, code) do
    {:ok, ast} = Code.string_to_quoted(code)

    {_, {vars, modules}} =
      Macro.prewalk(ast, {[], []}, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, {vars, modules} ->
          {node, {vars, [Module.concat(parts) | modules]}}

        {op, _, [pattern, _]} = node, {vars, modules} when op in [:=, :<-] ->
          {node, {pattern_vars(pattern) ++ vars, modules}}

        node, acc ->
          {node, acc}
      end)

    # What the block bound is unknown now; a later block that reads it is live.
    %{
      state
      | binding: Keyword.drop(state.binding, vars),
        live_vars: MapSet.union(state.live_vars, MapSet.new(vars)),
        live_modules: modules ++ state.live_modules
    }
  end

  defp pattern_vars(pattern) do
    {_, vars} =
      Macro.prewalk(pattern, [], fn
        {:^, _, _}, acc ->
          {:pinned, acc}

        {name, _, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  # A block is a sequence of expressions, each optionally followed by the
  # result it shows.
  defp segments(code) do
    {segments, current} =
      code
      |> String.split("\n")
      |> Enum.reduce({[], %{code: [], expected: nil}}, fn line, {done, current} ->
        cond do
          match = Regex.run(~r/^\s*#=>\s?(.*)$/, line) ->
            {done, %{current | expected: [Enum.at(match, 1)]}}

          current.expected != nil and Regex.match?(~r/^\s*#\s{3,}/, line) ->
            continued = Regex.replace(~r/^\s*#\s{3,}/, line, "")
            {done, %{current | expected: [continued | current.expected]}}

          current.expected != nil ->
            {[finish(current) | done], %{code: [line], expected: nil}}

          true ->
            {done, %{current | code: [line | current.code]}}
        end
      end)

    [finish(current) | segments]
    |> Enum.reverse()
    |> Enum.reject(&(String.trim(&1.code) == "" and &1.expected == nil))
  end

  defp finish(%{code: code, expected: expected}) do
    %{
      code: code |> Enum.reverse() |> Enum.join("\n"),
      expected: expected && expected |> Enum.reverse() |> Enum.join("\n")
    }
  end

  defp run_segment(%{code: code, expected: expected}, state) do
    before = :counters.get(state.requests, 1)

    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Code.eval_string(code, state.binding)}
        rescue
          error in [CompileError] -> {:compile_error, error}
          error in [UndefinedFunctionError] -> {:undefined, error, __STACKTRACE__}
          error -> {:raised, error, __STACKTRACE__}
        end
      end)

    undefined =
      for %{message: message} <- diagnostics,
          [_, name] <- [Regex.run(~r/undefined variable "(\w+)"/, message)],
          do: String.to_atom(name)

    sent_request? = :counters.get(state.requests, 1) > before

    case outcome do
      _ when sent_request? ->
        {:skip, :live}

      {:ok, {value, binding}} ->
        state = %{state | binding: binding}

        case expected && check(value, expected, binding) do
          nil -> {:ok, state}
          :ok -> {:ok, %{state | checked: state.checked + 1}}
          {:error, message} -> {:error, message}
        end

      {:compile_error, error} ->
        cond do
          Enum.any?(undefined, &MapSet.member?(state.live_vars, &1)) ->
            {:skip, :live}

          undefined != [] ->
            {:skip, :fragment}

          true ->
            {:error,
             Enum.map_join(diagnostics, "\n", & &1.message) <> "\n" <> Exception.message(error)}
        end

      {:undefined, %{module: module} = error, stacktrace} ->
        if module in state.live_modules,
          do: {:skip, :live},
          else: {:error, Exception.format(:error, error, stacktrace)}

      {:raised, error, stacktrace} ->
        {:error, Exception.format(:error, error, stacktrace)}
    end
  end

  defp check(value, expected, binding) do
    shown = fn -> "shows #{expected}, got #{inspect(value, pretty: true)}" end

    case Code.string_to_quoted(expected) do
      {:ok, quoted} ->
        case as_pattern(quoted, value) do
          true ->
            :ok

          false ->
            {:error, shown.()}

          :not_a_pattern ->
            case Code.eval_quoted(quoted, binding) do
              {^value, _} -> :ok
              _ -> {:error, shown.()}
            end
        end

      {:error, _} ->
        if squash(inspect(value, pretty: true)) == squash(expected),
          do: :ok,
          else: {:error, shown.()}
    end
  rescue
    error ->
      {:error, "shows #{expected}, which could not be checked: #{Exception.message(error)}"}
  end

  defp as_pattern(quoted, value) do
    {matched?, _diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {result, _} =
            Code.eval_quoted(quote(do: match?(unquote(quoted), var!(value))), value: value)

          result
        rescue
          CompileError -> :not_a_pattern
        end
      end)

    matched?
  end

  defp squash(text), do: text |> String.split() |> Enum.join(" ")

  defp in_scratch_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "imp-docs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = File.cwd!()

    try do
      File.cd!(dir)
      fun.()
    after
      File.cd!(original)
      File.rm_rf!(dir)
    end
  end

  ## Links and prose

  defp relative_links(page) do
    for {line, number} <- page |> File.read!() |> without_code() |> Enum.with_index(1),
        [_, target] <-
          Regex.scan(~r/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, line) ++
            Regex.scan(~r/\b(?:src|href)="([^"]+)"/, line),
        not String.match?(target, ~r/^(?:[a-z]+:|#)/),
        do: {target |> String.split("#") |> hd(), number}
  end

  defp resolve(page, target) do
    page |> Path.dirname() |> Path.join(target) |> Path.expand() |> Path.relative_to_cwd()
  end

  # ExDoc renders a link to another extra as a link to its page, and resolves
  # it by base name alone; it copies assets/. Anything else would be a broken
  # link on hexdocs, so it needs a full URL.
  defp link_failure(page, target, extras, by_name) do
    path = resolve(page, target)
    doc? = String.ends_with?(path, [".md", ".livemd", ".cheatmd"])

    cond do
      not File.exists?(path) ->
        "does not exist"

      doc? and not MapSet.member?(extras, path) ->
        "is not rendered; link to it by URL"

      doc? and by_name[Path.basename(path)] != [path] ->
        "shares its base name with another page"

      not doc? and not String.starts_with?(path, "assets/") ->
        "is not published; link to it by URL"

      true ->
        nil
    end
  end

  # Text lines with fenced code blanked, so line numbers still match the page.
  defp without_code(text) do
    text
    |> String.split("\n")
    |> Enum.map_reduce(nil, fn line, fence ->
      case {Regex.run(~r/^\s*(```|~~~)/, line), fence} do
        {[_, open], nil} -> {"", open}
        {[_, same], same} -> {"", nil}
        {_, nil} -> {line, nil}
        {_, fence} -> {"", fence}
      end
    end)
    |> elem(0)
  end

  defp prose(text) do
    text
    |> String.replace(~r/<!--.*?-->|<[^>]+>/s, &String.replace(&1, ~r/[^\n]/, ""))
    |> without_code()
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/`[^`]*`/, "")
      |> String.replace(~r/\]\([^)]*\)/, "]")
      |> String.replace(~r/https?:\/\/\S+/, "")
    end)
  end

  ## Mix commands

  defp invocable_mix_command?(task) do
    aliases =
      Mix.Project.config()
      |> Keyword.get(:aliases, [])
      |> Keyword.keys()
      |> MapSet.new(&Atom.to_string/1)

    cond do
      MapSet.member?(aliases, task) ->
        true

      module = Mix.Task.get(task) ->
        Code.ensure_loaded?(module) and function_exported?(module, :run, 1)

      true ->
        false
    end
  end
end
