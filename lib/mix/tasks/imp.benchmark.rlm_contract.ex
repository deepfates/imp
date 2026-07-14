defmodule Mix.Tasks.Imp.Benchmark.RlmContract do
  @moduledoc """
  Run matched T1 operational contracts against Imp RLM and current DSPy RLM.

  This task proves provider-free execution semantics. It does not measure
  long-context effectiveness and cannot satisfy the paper-scale release lane.
  """

  use Mix.Task

  @shortdoc "Run matched Imp/DSPy RLM operational contracts"
  @default_cases "test/fixtures/rlm_contract_cases.json"
  @default_out "tmp/rlm-contract"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [cases: :string, out: :string, python: :string]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    cases_path = Keyword.get(opts, :cases, @default_cases)
    out_dir = Keyword.get(opts, :out, @default_out)
    python = opts |> Keyword.get(:python, current_dspy_python()) |> Path.expand()
    File.mkdir_p!(out_dir)

    fixture =
      cases_path
      |> File.read!()
      |> Jason.decode!()
      |> Imp.Persistence.Legacy.rlm_contract_fixture()

    imp_rows = Enum.map(fixture["cases"], &run_imp_case/1)
    dspy = run_dspy!(python, cases_path, out_dir)
    artifact = compare(fixture, imp_rows, dspy)

    path =
      Path.join(out_dir, "rlm-operational-contract-#{timestamp_slug()}.json")
      |> Imp.BenchmarkTruth.ArtifactFile.write_json!(artifact)

    Mix.shell().info("RLM T1 operational contract: #{path}")

    unless artifact["summary"]["operational_contract_complete"] do
      Mix.raise("RLM T1 operational contract failed; inspect #{path}")
    end
  end

  defp run_imp_case(%{"disposition" => "deviation"} = contract) do
    base_row(contract)
    |> Map.merge(%{
      "executed" => false,
      "passing" => true,
      "status" => "supported_deviation",
      "output" => nil,
      "subcalls" => 0,
      "trace" => %{"entries" => [], "entry_count" => 0},
      "errors" => [],
      "deviation" => contract["deviation"]
    })
  end

  defp run_imp_case(contract) do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    Process.put(:rlm_contract_turns, contract["elixir_controller_code_turns"])

    controller = %{
      module: Imp.LM.Static,
      opts: [handler: controller_handler(contract)]
    }

    sub_lm = %{
      module: Imp.LM.Static,
      opts: [handler: sub_lm_handler(contract, calls)]
    }

    rlm =
      Imp.rlm(signature(contract),
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: get_in(contract, ["budgets", "max_iterations"]),
        max_llm_calls: get_in(contract, ["budgets", "max_llm_calls"])
      )

    result = Imp.call(rlm, contract["inputs"])
    prompts = Agent.get(calls, &Enum.reverse/1)
    Agent.stop(calls)
    row = evaluate_imp_result(contract, result, prompts)
    Process.delete(:rlm_contract_turns)
    row
  rescue
    error ->
      Process.delete(:rlm_contract_turns)

      base_row(contract)
      |> Map.merge(%{
        "executed" => true,
        "passing" => false,
        "status" => "error",
        "output" => nil,
        "subcalls" => 0,
        "trace" => %{"entries" => [], "entry_count" => 0},
        "errors" => [Exception.format(:error, error, __STACKTRACE__)]
      })
  end

  defp controller_handler(contract) do
    fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)

      if String.contains?(prompt, "RLM extract pass") do
        %{"answer" => contract["extract_output"]}
      else
        [code | rest] = Process.get(:rlm_contract_turns)
        Process.put(:rlm_contract_turns, rest)
        %{"reasoning" => "Execute trusted fixture turn.", "code" => code}
      end
    end
  end

  defp sub_lm_handler(contract, calls) do
    fn messages, _opts ->
      prompt = messages |> List.last() |> Map.fetch!(:content)
      Agent.update(calls, &[prompt | &1])

      if delay = get_in(contract, ["subresponse_delays_ms", prompt]) do
        Process.sleep(delay)
      end

      Map.fetch!(contract["subresponses"], prompt)
    end
  end

  defp evaluate_imp_result(contract, {:ok, prediction}, prompts) do
    trace = prediction.metadata[:trajectory] || []

    status =
      if Enum.any?(prediction.metadata.rlm_trace, &(&1.action == :extract)),
        do: "extracted",
        else: "submitted"

    expected = contract["expected"]
    output = Imp.get(prediction, :answer)

    errors =
      []
      |> check(output == expected["output"], "output mismatch")
      |> check(status == expected["status"], "status mismatch")
      |> check(length(prompts) == expected["subcalls"], "subcall count mismatch")
      |> check(
        length(trace) == get_in(expected, ["trace_shape", "entries"]),
        "trace entry count mismatch"
      )
      |> check(
        Enum.map(trace, & &1.code) == contract["elixir_controller_code_turns"],
        "trace code mismatch"
      )

    base_row(contract)
    |> Map.merge(%{
      "executed" => true,
      "passing" => errors == [],
      "status" => status,
      "output" => output,
      "subcalls" => length(prompts),
      "subcall_prompts" => prompts,
      "trace" => %{
        "entries" => Enum.map(trace, &json_safe/1),
        "entry_count" => length(trace),
        "final_reasoning" => prediction.metadata[:final_reasoning]
      },
      "errors" => Enum.reverse(errors)
    })
  end

  defp evaluate_imp_result(contract, {:error, reason}, prompts) do
    base_row(contract)
    |> Map.merge(%{
      "executed" => true,
      "passing" => false,
      "status" => "error",
      "output" => nil,
      "subcalls" => length(prompts),
      "subcall_prompts" => prompts,
      "trace" => %{"entries" => [], "entry_count" => 0},
      "errors" => [inspect(reason)]
    })
  end

  defp base_row(contract) do
    Map.take(contract, ["id", "invariant", "disposition", "required", "expected"])
  end

  defp check(errors, true, _message), do: errors
  defp check(errors, false, message), do: [message | errors]

  defp signature(%{"output_type" => "list[int]"}),
    do: "context, query -> answer: array[integer]"

  defp signature(contract) do
    case get_in(contract, ["expected", "output"]) do
      value when is_integer(value) -> "context, query -> answer: integer"
      _value -> "context, query -> answer: string"
    end
  end

  defp run_dspy!(python, cases_path, out_dir) do
    path = Path.join(out_dir, "dspy-rlm-operational-contract-#{timestamp_slug()}.json")

    case System.cmd(
           python,
           ["scripts/dspy_rlm_contract.py", "--cases", cases_path, "--out", path],
           stderr_to_stdout: true,
           env: current_dspy_env()
         ) do
      {_output, 0} ->
        path
        |> File.read!()
        |> Jason.decode!()
        |> Imp.Persistence.Legacy.rlm_contract_result()

      {output, status} ->
        Mix.raise("DSPy RLM contract failed with status #{status}:\n#{output}")
    end
  end

  defp compare(fixture, imp_rows, dspy) do
    dspy_by_id = Map.new(dspy["rows"], &{&1["id"], &1})

    rows =
      Enum.map(imp_rows, fn imp ->
        dspy_row = Map.fetch!(dspy_by_id, imp["id"])

        passing =
          if imp["disposition"] == "deviation" do
            imp["passing"] and dspy_row["passing"]
          else
            imp["passing"] and dspy_row["passing"] and
              imp["status"] == dspy_row["status"] and
              imp["output"] == dspy_row["output"] and
              imp["subcalls"] == dspy_row["subcalls"] and
              get_in(imp, ["trace", "entry_count"]) ==
                get_in(dspy_row, ["trace", "entry_count"])
          end

        %{
          "id" => imp["id"],
          "invariant" => imp["invariant"],
          "disposition" => imp["disposition"],
          "required" => imp["required"],
          "passing" => passing,
          "imp" => imp,
          "dspy" => dspy_row
        }
      end)

    required = Enum.filter(rows, &(&1["disposition"] == "matched" and &1["required"] == true))
    matched = Enum.filter(rows, &(&1["disposition"] == "matched"))
    complete = length(matched) >= 10 and required != [] and Enum.all?(required, & &1["passing"])

    %{
      "schema_version" => 1,
      "evidence_tier" => "t1_operational_contract",
      "claim_scope" => "provider-free matched RLM execution semantics only",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "fixture" => %{
        "schema_version" => fixture["schema_version"],
        "purpose" => fixture["purpose"],
        "sha256" =>
          fixture
          |> Jason.encode!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)
      },
      "dspy" =>
        Map.take(dspy, [
          "dspy_version",
          "python_version",
          "upstream_source_sha256",
          "upstream_source_path"
        ]),
      "summary" => %{
        "total_cases" => length(rows),
        "matched_cases" => length(matched),
        "required_matched_cases" => length(required),
        "required_matched_passing" => Enum.count(required, & &1["passing"]),
        "supported_deviations" => Enum.count(rows, &(&1["disposition"] == "deviation")),
        "operational_contract_complete" => complete,
        "paper_protocol_complete" => false,
        "scope" =>
          "T1 operational semantics; not long-context effectiveness or paper reproduction"
      },
      "rows" => rows
    }
  end

  defp json_safe(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value) when is_struct(value), do: inspect(value)
  defp json_safe(value), do: value

  defp current_dspy_python do
    System.get_env("IMP_DSPY_CURRENT_PYTHON") || "tmp/dspy-parity-venv/bin/python"
  end

  defp current_dspy_env do
    case System.get_env("IMP_DSPY_CURRENT_PYTHONPATH") do
      nil ->
        target = Path.expand("tmp/dspy-current-target")

        if File.dir?(Path.join(target, "dspy")) do
          [{"PYTHONPATH", target}]
        else
          []
        end

      path ->
        [{"PYTHONPATH", Path.expand(path)}]
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp timestamp_slug,
    do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
