defmodule Imp.BenchmarkTruth.RLMRuntimeDifferential do
  @moduledoc false

  alias Imp.Predict.RLM
  alias Imp.Predict.RLM.{Interpreter, Session}

  alias Imp.BenchmarkTruth.{ArtifactFile, Paths}

  @default_manifest "benchmarks/config/rlm-runtime-differential-v1.json"
  @default_python "tmp/rlm-upstream/.venv/bin/python"
  @default_upstream "tmp/rlm-upstream"
  @runner "scripts/rlm_runtime_differential.py"
  @imp_sources [
    "lib/imp/predict/rlm.ex",
    "lib/imp/predict/rlm/budget.ex",
    "lib/imp/predict/rlm/compaction.ex",
    "lib/imp/predict/rlm/interpreter.ex",
    "lib/imp/predict/rlm/runtime.ex",
    "lib/imp/predict/rlm/session.ex"
  ]
  @harness_sources [
    "bench/imp/benchmark_truth/rlm_runtime_differential.ex",
    "lib/mix/tasks/imp.benchmark.rlm_runtime_differential.ex",
    "scripts/rlm_runtime_differential.py"
  ]

  def readiness(opts \\ []) do
    manifest_path = opts |> Keyword.get(:manifest, @default_manifest) |> Path.expand()
    upstream = opts |> Keyword.get(:upstream, @default_upstream) |> Path.expand()
    python = opts |> Keyword.get(:python, @default_python) |> Path.expand()

    cond do
      not File.regular?(manifest_path) ->
        {:error, "manifest is missing: #{manifest_path}"}

      not File.dir?(upstream) or not File.exists?(Path.join(upstream, ".git")) ->
        {:error, "pinned standalone RLM checkout is missing: #{upstream}"}

      not File.regular?(python) ->
        {:error, "pinned Python executable is missing: #{python}"}

      true ->
        manifest = read_json!(manifest_path)
        verify_manifest!(manifest)
        _authority = verify_authority!(manifest, upstream)

        case System.cmd(python, ["--version"], stderr_to_stdout: true) do
          {_output, 0} -> {:ok, %{manifest: manifest_path, upstream: upstream, python: python}}
          {output, status} -> {:error, "Python readiness command failed (#{status}): #{output}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def run(opts \\ []) do
    manifest_path = opts |> Keyword.get(:manifest, @default_manifest) |> Path.expand()
    upstream = opts |> Keyword.get(:upstream, @default_upstream) |> Path.expand()
    python = opts |> Keyword.get(:python, @default_python) |> Path.expand()
    manifest = read_json!(manifest_path)
    verify_manifest!(manifest)

    case readiness(manifest: manifest_path, upstream: upstream, python: python) do
      {:ok, _ready} -> :ok
      {:error, reason} -> raise ArgumentError, "RLM differential setup is not ready: #{reason}"
    end

    official = run_official!(python, manifest_path, upstream, opts)
    verify_official!(official, manifest, manifest_path)

    imp_rows = Enum.map(manifest["cases"], &run_imp_case/1)
    compare(manifest, manifest_path, official, imp_rows)
  end

  def validate_artifact!("rlm_runtime_differential", artifact) when is_map(artifact) do
    validate_artifact!(artifact, %{"manifest" => @default_manifest})
    :ok
  end

  def validate_artifact!(artifact, protocol) when is_map(artifact) and is_map(protocol) do
    manifest_path = protocol["manifest"] || @default_manifest
    manifest = read_json!(manifest_path)
    verify_manifest!(manifest)
    validate_artifact_identity!(artifact, manifest, manifest_path)

    cases_by_id = Map.new(manifest["cases"], &{&1["id"], &1})

    rows =
      Enum.map(artifact["rows"], fn row ->
        case = Map.fetch!(cases_by_id, row["id"])
        validate_artifact_row!(row, case)
        row
      end)

    unless artifact["summary"] == summarize(manifest, rows, artifact["upstream_tests"]) do
      raise ArgumentError, "standalone RLM artifact summary is not mechanically derived"
    end

    verify_committed_sources!(
      artifact["git_sha"],
      get_in(artifact, ["runtimes", "imp", "source_files"]),
      "Imp RLM"
    )

    verify_committed_sources!(
      artifact["git_sha"],
      artifact["harness_files"],
      "RLM differential harness"
    )

    artifact
  rescue
    error ->
      reraise ArgumentError,
              [
                message:
                  "invalid standalone RLM differential artifact: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def validate_artifact!(_artifact, _protocol),
    do: raise(ArgumentError, "invalid standalone RLM differential artifact")

  defp run_imp_case(case) do
    base =
      Map.take(case, [
        "id",
        "category",
        "comparison",
        "required",
        "invariant",
        "authority_tests",
        "boundary"
      ])

    expected = expected(case, "imp")

    try do
      {{canonical, details}, boundary_evidence} =
        observe_imp_boundary(get_in(case, ["boundary", "imp"]), fn ->
          run_imp_case!(case["id"])
        end)

      details = Map.put(details, "boundary_evidence", boundary_evidence)
      passing = canonical == expected
      boundary_valid = valid_boundary?(boundary_evidence, get_in(case, ["boundary", "imp"]))

      Map.merge(base, %{
        "executed" => true,
        "real_boundary" => boundary_valid,
        "passing" => passing and boundary_valid,
        "expected" => expected,
        "canonical" => canonical,
        "details" => details,
        "errors" =>
          Enum.reject(
            [
              if(passing, do: nil, else: "canonical observation mismatch"),
              if(boundary_valid, do: nil, else: "public boundary observation missing or invalid")
            ],
            &is_nil/1
          )
      })
    rescue
      error ->
        Map.merge(base, %{
          "executed" => true,
          "real_boundary" => false,
          "passing" => false,
          "expected" => expected,
          "canonical" => nil,
          "details" => %{},
          "errors" => [Exception.format(:error, error, __STACKTRACE__)]
        })
    catch
      kind, reason ->
        Map.merge(base, %{
          "executed" => true,
          "real_boundary" => false,
          "passing" => false,
          "expected" => expected,
          "canonical" => nil,
          "details" => %{},
          "errors" => [Exception.format(kind, reason, __STACKTRACE__)]
        })
    end
  end

  defp run_imp_case!("continuous_root_transcript") do
    parent = self()

    handler = fn messages, _opts ->
      payload = controller_payload(messages)

      if payload["iteration"] == 1 do
        %{code: ~S|scratch = context <> "-derived"
print("stage:" <> scratch)|}
      else
        send(parent, {:rlm_differential_second_turn, messages})
        %{code: ~S|submit(%{answer: scratch})|}
      end
    end

    rlm = RLM.new("context -> answer", lm: static_lm(handler), max_iterations: 2)
    {:ok, prediction} = RLM.call(rlm, %{context: "alpha"})

    messages =
      receive do
        {:rlm_differential_second_turn, messages} -> messages
      after
        1_000 -> raise "second RLM controller turn was not observed"
      end

    saw_stage = Enum.any?(messages, &(message_content(&1) =~ "stage:alpha-derived"))

    canonical = %{
      "continuous_transcript" => saw_stage,
      "controller_iterations" => prediction.metadata.rlm.iterations,
      "output" => Imp.Prediction.get(prediction, :answer)
    }

    {canonical, %{"second_turn_roles" => Enum.map(messages, &message_role/1)}}
  end

  defp run_imp_case!("protected_context_alias") do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{code: ~S|context = "hijacked"
print(context)|},
          %{code: ~S|submit(%{answer: context})|}
        ]
      end)

    try do
      rlm =
        RLM.new("context -> answer",
          lm: queued_lm(actions),
          max_iterations: 2
        )

      {:ok, prediction} = RLM.call(rlm, %{context: "original"})
      output = Imp.Prediction.get(prediction, :answer)

      {%{"context" => output, "restored" => output == "original"}, %{}}
    after
      if Process.alive?(actions), do: Agent.stop(actions)
    end
  end

  defp run_imp_case!("persistent_context_versioning") do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{code: ~S|scratch = context <> "-derived"
submit(%{answer: scratch})|},
          %{code: ~S|submit(%{answer: context_0 <> ":" <> context_1 <> ":" <> scratch})|}
        ]
      end)

    rlm =
      RLM.new("context -> answer",
        lm: queued_lm(actions),
        persistent: true,
        max_iterations: 1
      )

    try do
      {:ok, first} = RLM.call(rlm, %{context: "first"})
      {:ok, second} = RLM.call(rlm, %{context: "second"})

      counts =
        Session.transaction(rlm.session, fn snapshot ->
          %{
            "context_count" => snapshot.context_count,
            "history_count" => snapshot.history_count
          }
        end)

      canonical =
        Map.merge(counts, %{
          "first_output" => Imp.Prediction.get(first, :answer),
          "second_output" => Imp.Prediction.get(second, :answer)
        })

      {canonical, %{"session" => "Imp.Predict.RLM.Session"}}
    after
      RLM.close(rlm)
      if Process.alive?(actions), do: Agent.stop(actions)
    end
  end

  defp run_imp_case!("compaction_public_prompt_transition") do
    {:ok, calls} = Agent.start_link(fn -> %{count: 0, prompts: []} end)
    {trajectory_comment, trajectory_probes} = compaction_trajectory()

    handler = fn messages, _opts ->
      Agent.update(calls, fn state ->
        %{state | count: state.count + 1, prompts: state.prompts ++ [messages]}
      end)

      content = messages |> List.last() |> message_content()

      if String.starts_with?(content, "Summarize your progress so far") do
        "summary-without-raw-marker"
      else
        case Jason.decode!(content)["iteration"] do
          1 ->
            %{
              code:
                "# " <>
                  trajectory_comment <>
                  "\n" <>
                  ~S|scratch = context <> "-derived"
print("recover-me")|
            }

          2 ->
            %{code: ~S|submit(%{answer: "done"})|}
        end
      end
    end

    try do
      rlm =
        RLM.new("context -> answer",
          lm: static_lm(handler),
          max_iterations: 2,
          compaction: true,
          compaction_threshold_pct: 0.01,
          compaction_context_tokens: 100
        )

      {:ok, prediction} = RLM.call(rlm, %{context: "alpha"})
      prompts = Agent.get(calls, & &1.prompts)
      summary_prompt_text = compact_prompt_text(prompts, :summary)
      next_prompt_text = compact_prompt_text(prompts, :next)

      canonical = %{
        "controller_iterations" => prediction.metadata.rlm.iterations,
        "root_model_calls" => Agent.get(calls, & &1.count),
        "summary_request_observed" => compact_summary_requested?(prompts),
        "next_prompt_shorter" => compact_prompt_shorter?(prompts),
        "summary_prompt_has_full_raw_trajectory" =>
          String.contains?(summary_prompt_text, trajectory_comment),
        "next_prompt_has_full_raw_trajectory" =>
          String.contains?(next_prompt_text, trajectory_comment),
        "trajectory_probe_count" => length(trajectory_probes),
        "summary_prompt_trajectory_probes_observed" =>
          count_observed_markers(summary_prompt_text, trajectory_probes),
        "next_prompt_trajectory_probes_observed" =>
          count_observed_markers(next_prompt_text, trajectory_probes),
        "trajectory_bytes" => byte_size(trajectory_comment),
        "trajectory_sha256" => sha256(trajectory_comment),
        "next_prompt_has_summary" =>
          compact_next_prompt_contains?(prompts, "summary-without-raw-marker")
      }

      {canonical,
       %{
         "prompt_count_observed" => length(prompts),
         "prompt_sizes_observed" => compact_prompt_sizes(prompts),
         "trajectory_probe_scheme" =>
           "16 deterministic probes interleaved across 100000 fixed-width hexadecimal values"
       }}
    after
      if Process.alive?(calls), do: Agent.stop(calls)
    end
  end

  defp run_imp_case!("recursive_depth_boundary") do
    parent = self()

    controller = %{
      module: Imp.LM.Static,
      opts: [
        model: "parent-model",
        handler: fn _messages, _opts ->
          %{
            code: ~S|reply = rlm_query("leaf prompt", "child-model")
submit(%{answer: reply})|
          }
        end
      ]
    }

    sub_lm =
      static_lm(fn _messages, opts ->
        send(parent, {:rlm_differential_leaf, Keyword.get(opts, :model)})
        "leaf response"
      end)

    rlm =
      RLM.new("context -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_recursion_depth: 1
      )

    parent_before = Keyword.fetch!(rlm.lm.opts, :model)
    {:ok, prediction} = RLM.call(rlm, %{context: "root"})
    parent_after = Keyword.fetch!(rlm.lm.opts, :model)

    requested_model =
      receive do
        {:rlm_differential_leaf, model} -> model
      after
        1_000 -> raise "depth-boundary sub-LM call was not observed"
      end

    canonical = %{
      "depth_boundary_fallback" =>
        prediction.metadata.rlm.sub_lm_calls == 1 and
          prediction.metadata.rlm.max_observed_depth == 0,
      "output" => Imp.Prediction.get(prediction, :answer),
      "parent_model" => if(parent_before == parent_after, do: parent_after, else: "mutated"),
      "requested_model" => requested_model
    }

    {canonical,
     %{
       "child_trace_count" => length(prediction.metadata.rlm_child_traces),
       "sub_lm_calls" => prediction.metadata.rlm.sub_lm_calls
     }}
  end

  defp run_imp_case!("bounded_ordered_recursive_fanout") do
    parent = self()
    {:ok, concurrency} = Agent.start_link(fn -> %{active: 0, max_active: 0, calls: 0} end)

    handler = fn messages, _opts ->
      payload = controller_payload(messages)
      context = get_in(payload, ["variables", "context", "preview"])

      if context == "parent" do
        %{
          code: ~S"""
          items = rlm_query_batched(["slow", "bad", "fast"], "child-model")
          submit(%{answer: Enum.join(items, "|")})
          """
        }
      else
        send(parent, {:rlm_differential_child, context})

        Agent.update(concurrency, fn state ->
          active = state.active + 1

          %{
            state
            | active: active,
              max_active: max(active, state.max_active),
              calls: state.calls + 1
          }
        end)

        try do
          Process.sleep(%{"slow" => 50, "bad" => 20, "fast" => 10}[context])

          if context == "bad" do
            raise "intentional child failure"
          else
            %{code: "submit(%{answer: " <> inspect(context) <> "})"}
          end
        after
          Agent.update(concurrency, &%{&1 | active: &1.active - 1})
        end
      end
    end

    try do
      rlm =
        RLM.new("context -> answer",
          lm: static_lm(handler),
          max_iterations: 1,
          max_recursion_depth: 2,
          max_concurrent_subcalls: 2
        )

      {:ok, prediction} = RLM.call(rlm, %{context: "parent"})

      normalized =
        prediction
        |> Imp.Prediction.get(:answer)
        |> String.split("|")
        |> Enum.map(fn value ->
          if(String.starts_with?(value, "Error:"), do: "error", else: value)
        end)

      stats = Agent.get(concurrency, & &1)

      canonical = %{
        "call_count" => stats.calls,
        "max_concurrency" => stats.max_active,
        "ordered_results" => normalized
      }

      child_contexts =
        for _index <- 1..3 do
          receive do
            {:rlm_differential_child, context} -> context
          after
            1_000 -> raise "recursive child was not observed"
          end
        end

      {canonical, %{"child_contexts" => Enum.sort(child_contexts)}}
    after
      if Process.alive?(concurrency), do: Agent.stop(concurrency)
    end
  end

  defp run_imp_case!("expired_deadline_prevents_subcall") do
    parent = self()

    controller =
      static_lm(fn _messages, _opts ->
        Process.sleep(10)
        %{code: ~S|reply = rlm_query("too late")
submit(%{answer: reply})|}
      end)

    sub_lm =
      static_lm(fn _messages, _opts ->
        send(parent, :rlm_differential_unexpected_subcall)
        "unexpected"
      end)

    rlm =
      RLM.new("context -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_recursion_depth: 1,
        max_time_ms: 1
      )

    result = RLM.call(rlm, %{context: "root"})

    subcall_started =
      receive do
        :rlm_differential_unexpected_subcall -> true
      after
        20 -> false
      end

    status = if match?({:error, {:rlm_max_time_ms, 1, _trace}}, result), do: "bounded_failure"

    {%{"status" => status, "subcall_started" => subcall_started},
     %{"result" => inspect(result, limit: 20)}}
  end

  defp run_imp_case!("local_code_capability") do
    interpreter = Interpreter.new(%{}, %{}, nil)

    result =
      Interpreter.execute(
        interpreter,
        "import :math, only: [sqrt: 1]\nvalue = :math.sqrt(9)"
      )

    imports_allowed = match?({:ok, _value, _next}, result)

    value =
      case result do
        {:ok, _value, next} -> Map.get(next.vars, :value, Map.get(next.vars, "value"))
        _ -> nil
      end

    {%{
       "imports_allowed" => imports_allowed,
       "value" => if(imports_allowed, do: value, else: nil),
       "runtime" => "constrained_beam_allowlist"
     },
     %{
       "result" => inspect(result, limit: 20),
       "source" => "import :math, only: [sqrt: 1]; value = :math.sqrt(9)"
     }}
  end

  defp run_imp_case!("assignment_before_cell_error") do
    interpreter = Interpreter.new(%{context: "original"}, %{}, nil)

    {:error, _reason, next} =
      Interpreter.execute(interpreter, ~S|scratch = context <> "-saved"
missing()|)

    survives = Map.get(next.vars, :scratch, Map.get(next.vars, "scratch")) == "original-saved"

    {%{"assignment_survives_error" => survives}, %{}}
  end

  defp compact_prompt_shorter?([_first, summary, next | _]) do
    byte_size(Jason.encode!(next)) < byte_size(Jason.encode!(summary))
  end

  defp compact_prompt_shorter?(_prompts), do: false

  defp compact_summary_requested?([_first, summary | _]) do
    summary
    |> List.last()
    |> message_content()
    |> String.starts_with?("Summarize your progress so far")
  end

  defp compact_summary_requested?(_prompts), do: false

  defp compact_prompt_sizes([first, summary, next | _]) do
    %{
      "first" => byte_size(Jason.encode!(first)),
      "summary" => byte_size(Jason.encode!(summary)),
      "next" => byte_size(Jason.encode!(next))
    }
  end

  defp compact_prompt_sizes(_prompts), do: %{}

  defp compact_next_prompt_contains?([_first, _summary, next | _], marker) do
    Enum.any?(next, &(message_content(&1) =~ marker))
  end

  defp compact_next_prompt_contains?(_prompts, _marker), do: false

  defp compact_prompt_text([_first, summary, _next | _], :summary), do: Jason.encode!(summary)
  defp compact_prompt_text([_first, _summary, next | _], :next), do: Jason.encode!(next)
  defp compact_prompt_text(_prompts, _position), do: ""

  defp count_observed_markers(text, markers) do
    Enum.count(markers, &String.contains?(text, &1))
  end

  defp compaction_trajectory do
    probe_count = 16
    values_per_probe = 6_250

    parts =
      Enum.flat_map(0..(probe_count - 1), fn probe_index ->
        start = probe_index * values_per_probe

        values =
          start..(start + values_per_probe - 1)
          |> Enum.map(fn value ->
            value
            |> Integer.to_string(16)
            |> String.downcase()
            |> String.pad_leading(8, "0")
          end)

        probe_seed = "imp-rlm-trajectory-probe-#{probe_index}"

        probe =
          "imp-rlm-trajectory-probe-" <>
            String.pad_leading(Integer.to_string(probe_index), 2, "0") <>
            "-" <> sha256(probe_seed)

        [values, probe]
      end)

    trajectory = IO.iodata_to_binary(parts)
    probes = Enum.map(0..(probe_count - 1), &compaction_probe/1)
    {trajectory, probes}
  end

  defp compaction_probe(index) do
    "imp-rlm-trajectory-probe-" <>
      String.pad_leading(Integer.to_string(index), 2, "0") <>
      "-" <> sha256("imp-rlm-trajectory-probe-#{index}")
  end

  defp compare(manifest, manifest_path, official, imp_rows) do
    official_by_id = Map.new(official["rows"], &{&1["id"], &1})

    rows =
      Enum.map(imp_rows, fn imp ->
        official_row = Map.fetch!(official_by_id, imp["id"])

        passing =
          imp["passing"] and official_row["passing"] and
            case imp["comparison"] do
              "matched" -> imp["canonical"] == official_row["canonical"]
              "declared_deviation" -> imp["canonical"] != official_row["canonical"]
            end

        %{
          "id" => imp["id"],
          "category" => imp["category"],
          "comparison" => imp["comparison"],
          "required" => imp["required"],
          "invariant" => imp["invariant"],
          "authority_tests" => imp["authority_tests"],
          "boundary" => imp["boundary"],
          "passing" => passing,
          "official" => official_row,
          "imp" => imp
        }
      end)

    %{
      "schema_version" => 1,
      "runner" => "imp-standalone-rlm-runtime-differential",
      "protocol_id" => manifest["protocol_id"],
      "evidence_tier" => "t1_pinned_runtime_differential",
      "claim_scope" => manifest["claim_scope"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "fixture" => %{
        "path" => Path.relative_to_cwd(manifest_path),
        "sha256" => sha256_file(manifest_path)
      },
      "authority" => official["authority"],
      "runtimes" => %{
        "official" =>
          Map.take(official, [
            "runner",
            "runtime",
            "python_version",
            "loaded_source",
            "runner_source"
          ]),
        "imp" => %{
          "runtime" => "beam_constrained_elixir",
          "otp_release" => to_string(:erlang.system_info(:otp_release)),
          "elixir_version" => System.version(),
          "source_files" => Map.new(@imp_sources, &{&1, sha256_file(&1)})
        }
      },
      "upstream_tests" => official["upstream_tests"],
      "harness_files" => Map.new(@harness_sources, &{&1, sha256_file(&1)}),
      "summary" => summarize(manifest, rows, official["upstream_tests"]),
      "rows" => rows
    }
  end

  defp summarize(manifest, rows, upstream_tests) do
    required_categories = MapSet.new(manifest["required_categories"])
    covered_categories = rows |> Enum.map(& &1["category"]) |> MapSet.new()
    category_coverage = MapSet.subset?(required_categories, covered_categories)
    required = Enum.filter(rows, & &1["required"])
    matched = Enum.filter(required, &(&1["comparison"] == "matched"))
    deviations = Enum.filter(required, &(&1["comparison"] == "declared_deviation"))
    all_required = required != [] and Enum.all?(required, & &1["passing"])
    all_boundaries = Enum.all?(required, &real_boundaries?/1)
    c1 = category_coverage and matched != [] and deviations != [] and all_required
    upstream_tests_passed = valid_upstream_tests?(manifest, upstream_tests)
    c2 = c1 and all_boundaries and upstream_tests_passed

    %{
      "total_cases" => length(rows),
      "required_cases" => length(required),
      "required_passing" => Enum.count(required, & &1["passing"]),
      "matched_cases" => length(matched),
      "declared_deviations" => length(deviations),
      "required_categories" => Enum.sort(manifest["required_categories"]),
      "covered_categories" => covered_categories |> MapSet.to_list() |> Enum.sort(),
      "category_coverage_complete" => category_coverage,
      "upstream_authority_tests_passed" => upstream_tests_passed,
      "c1_behavioral_conformance" => c1,
      "c2_provider_free_operation" => c2,
      "highest_satisfied_rung" => if(c2, do: "C2", else: if(c1, do: "C1", else: "C0")),
      "differential_complete" => c2,
      "paper_protocol_complete" => false,
      "effectiveness_claimed" => false
    }
  end

  defp real_boundaries?(row),
    do: get_in(row, ["official", "real_boundary"]) and get_in(row, ["imp", "real_boundary"])

  defp run_official!(python, manifest, upstream, opts) do
    explicit_out = Keyword.get(opts, :official_out)

    path =
      explicit_out ||
        Path.join(
          System.tmp_dir!(),
          ArtifactFile.artifact_name("imp-rlm-runtime-official", [])
        )

    path = Paths.prepare_file_path!(Path.dirname(path), Path.basename(path))

    try do
      case System.cmd(
             python,
             [
               @runner,
               "--manifest",
               manifest,
               "--upstream",
               upstream,
               "--out",
               path
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> read_json!(path)
        {output, status} -> raise "official RLM differential failed with #{status}:\n#{output}"
      end
    after
      if is_nil(explicit_out), do: File.rm(path)
    end
  end

  defp verify_authority!(manifest, upstream) do
    authority = manifest["authority"]
    commit = git_sha_for!(upstream)

    unless commit == authority["commit"],
      do:
        raise(
          ArgumentError,
          "standalone RLM commit mismatch: expected #{authority["commit"]}, got #{commit}"
        )

    unless System.cmd("git", ["-C", upstream, "diff", "--quiet", "HEAD"]) |> elem(1) == 0,
      do: raise(ArgumentError, "standalone RLM checkout has tracked modifications")

    Enum.each(authority["files"], fn {relative, expected} ->
      path = Path.join(upstream, relative)

      unless File.regular?(path) and sha256_file(path) == expected,
        do: raise(ArgumentError, "standalone RLM source mismatch for #{relative}")
    end)

    authority
  end

  defp git_sha_for!(upstream) do
    case System.cmd("git", ["-C", upstream, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        String.trim(sha)

      {output, status} ->
        raise ArgumentError, "cannot read standalone RLM revision (#{status}): #{output}"
    end
  end

  defp verify_manifest!(manifest) do
    unless manifest["schema_version"] == 1 and is_list(manifest["cases"]) and
             manifest["cases"] != [] and is_list(manifest["required_categories"]) do
      raise ArgumentError, "invalid standalone RLM differential manifest"
    end

    unless is_map(manifest["authority"]) and is_list(manifest["authority"]["selected_tests"]) and
             manifest["authority"]["selected_tests"] != [] do
      raise ArgumentError, "RLM differential authority test suite is missing"
    end

    ids = Enum.map(manifest["cases"], & &1["id"])
    unless ids == Enum.uniq(ids), do: raise(ArgumentError, "RLM differential case ids repeat")

    unknown = ids -- imp_case_ids()

    unless unknown == [] and length(ids) == length(imp_case_ids()) do
      raise ArgumentError,
            "RLM differential runner/manifest mismatch: unknown=#{inspect(unknown)}"
    end

    unless Enum.all?(manifest["cases"], fn case ->
             is_map(case["boundary"]) and
               valid_official_boundary_spec?(get_in(case, ["boundary", "official"])) and
               valid_imp_boundary_spec?(get_in(case, ["boundary", "imp"]))
           end) do
      raise ArgumentError, "RLM differential case boundary inventory is invalid"
    end
  end

  defp verify_official!(official, manifest, manifest_path) do
    expected_ids = Enum.map(manifest["cases"], & &1["id"])
    actual_ids = Enum.map(official["rows"], & &1["id"])

    conditions = [
      official["schema_version"] == 1,
      official["runtime"] == "official",
      get_in(official, ["summary", "all_cases_pass"]) == true,
      get_in(official, ["summary", "all_public_boundary_evidence"]) == true,
      get_in(official, ["authority", "commit"]) == get_in(manifest, ["authority", "commit"]),
      get_in(official, ["authority", "files"]) == get_in(manifest, ["authority", "files"]),
      valid_upstream_tests?(manifest, official["upstream_tests"]),
      get_in(official, ["fixture", "sha256"]) == sha256_file(manifest_path),
      expected_ids == actual_ids
    ]

    unless Enum.all?(conditions), do: raise(ArgumentError, "invalid official RLM artifact")
  end

  defp validate_artifact_identity!(artifact, manifest, manifest_path) do
    expected_ids = Enum.map(manifest["cases"], & &1["id"])
    actual_ids = Enum.map(artifact["rows"], & &1["id"])

    conditions = [
      artifact["schema_version"] == 1,
      artifact["runner"] == "imp-standalone-rlm-runtime-differential",
      artifact["protocol_id"] == manifest["protocol_id"],
      artifact["evidence_tier"] == "t1_pinned_runtime_differential",
      artifact["claim_scope"] == manifest["claim_scope"],
      artifact["authority"] == manifest["authority"],
      valid_upstream_tests?(manifest, artifact["upstream_tests"]),
      get_in(artifact, ["fixture", "sha256"]) == sha256_file(manifest_path),
      expected_ids == actual_ids,
      Map.keys(artifact["harness_files"] || %{}) |> Enum.sort() == Enum.sort(@harness_sources),
      get_in(artifact, ["runtimes", "imp", "runtime"]) == "beam_constrained_elixir",
      get_in(artifact, ["runtimes", "official", "runtime"]) == "official"
    ]

    unless Enum.all?(conditions),
      do: raise(ArgumentError, "standalone RLM artifact identity mismatch")
  end

  defp validate_artifact_row!(row, case) do
    official = Map.fetch!(row, "official")
    imp = Map.fetch!(row, "imp")
    official_expected = expected(case, "official")
    imp_expected = expected(case, "imp")

    base_matches =
      Enum.all?(
        ["id", "category", "comparison", "required", "invariant", "authority_tests", "boundary"],
        &(row[&1] == case[&1])
      )

    runtime_rows_valid =
      Enum.all?([{official, official_expected, "official"}, {imp, imp_expected, "imp"}], fn
        {runtime, expected, runtime_name} ->
          runtime["executed"] == true and runtime["real_boundary"] == true and
            runtime["passing"] == true and runtime["expected"] == expected and
            runtime["canonical"] == expected and runtime["errors"] == [] and
            valid_boundary?(
              runtime["details"]["boundary_evidence"],
              get_in(case, ["boundary", runtime_name])
            )
      end)

    comparison_valid =
      case case["comparison"] do
        "matched" -> official["canonical"] == imp["canonical"]
        "declared_deviation" -> official["canonical"] != imp["canonical"]
      end

    unless base_matches and runtime_rows_valid and comparison_valid and row["passing"] == true do
      raise ArgumentError, "standalone RLM row #{inspect(case["id"])} is not derivable"
    end
  end

  defp verify_committed_sources!(git_sha, files, label)
       when is_binary(git_sha) and is_map(files) and map_size(files) > 0 do
    unless Regex.match?(~r/^[0-9a-f]{40}$/, git_sha) do
      raise ArgumentError, "#{label} artifact has an invalid git revision"
    end

    Enum.each(files, fn {path, expected} ->
      case System.cmd("git", ["show", "#{git_sha}:#{path}"], stderr_to_stdout: true) do
        {bytes, 0} ->
          actual = sha256(bytes)

          unless actual == expected do
            raise ArgumentError,
                  "#{label} source #{path} does not match committed revision #{git_sha}"
          end

        {_output, _status} ->
          raise ArgumentError, "#{label} source #{path} is absent from revision #{git_sha}"
      end
    end)
  end

  defp verify_committed_sources!(_git_sha, _files, label),
    do: raise(ArgumentError, "#{label} source inventory is invalid")

  defp valid_upstream_tests?(manifest, tests) when is_map(tests) do
    tests["runner"] == "pytest" and
      tests["command"] == [
        "python",
        "-m",
        "pytest",
        "-q" | manifest["authority"]["selected_tests"]
      ] and
      tests["tests"] == manifest["authority"]["selected_tests"] and
      tests["status"] == "passed" and tests["exit_code"] == 0 and
      is_binary(tests["stdout"]) and is_binary(tests["stderr"]) and
      tests["summary"] == pytest_summary(tests["stdout"]) and
      tests["output_sha256"] ==
        sha256(canonical_pytest_evidence(tests["exit_code"], tests["stdout"], tests["stderr"]))
  end

  defp valid_upstream_tests?(_manifest, _tests), do: false

  defp valid_boundary?(evidence, %{"kind" => "public_method"} = expected)
       when is_map(evidence) do
    evidence["mechanism"] == "python_public_method_wrapper" and
      evidence["module"] == expected["module"] and
      evidence["class"] == expected["class"] and
      evidence["method"] == expected["method"] and evidence["method_is_public"] == true and
      is_integer(evidence["observed_invocations"]) and
      evidence["observed_invocations"] >= expected["minimum_invocations"] and
      is_list(evidence["call_shapes"]) and
      length(evidence["call_shapes"]) == evidence["observed_invocations"] and
      Enum.all?(evidence["call_shapes"], &valid_python_call_shape?/1)
  end

  defp valid_boundary?(evidence, %{"kind" => "exported_call"} = expected)
       when is_map(evidence) do
    evidence["mechanism"] == "erlang_call_trace" and
      evidence["module"] == expected["module"] and
      evidence["function"] == expected["function"] and evidence["arity"] == expected["arity"] and
      evidence["exported"] == true and is_integer(evidence["trace_pattern_matches"]) and
      evidence["trace_pattern_matches"] > 0 and is_integer(evidence["observed_invocations"]) and
      evidence["observed_invocations"] >= expected["minimum_invocations"]
  end

  defp valid_boundary?(_evidence, _expected), do: false

  defp valid_python_call_shape?(%{"positional_arguments" => count, "keyword_arguments" => keys})
       when is_integer(count) and count >= 0 and is_list(keys),
       do: Enum.all?(keys, &is_binary/1)

  defp valid_python_call_shape?(_shape), do: false

  defp valid_official_boundary_spec?(%{
         "kind" => "public_method",
         "module" => module,
         "class" => class,
         "method" => method,
         "minimum_invocations" => minimum
       }) do
    is_binary(module) and is_binary(class) and is_binary(method) and method != "" and
      not String.starts_with?(method, "_") and is_integer(minimum) and minimum > 0
  end

  defp valid_official_boundary_spec?(_boundary), do: false

  defp valid_imp_boundary_spec?(%{
         "kind" => "exported_call",
         "module" => module,
         "function" => function,
         "arity" => arity,
         "minimum_invocations" => minimum
       }) do
    is_binary(module) and is_binary(function) and function != "" and is_integer(arity) and
      arity >= 0 and
      is_integer(minimum) and minimum > 0
  end

  defp valid_imp_boundary_spec?(_boundary), do: false

  defp canonical_pytest_evidence(exit_code, stdout, stderr)
       when is_integer(exit_code) and is_binary(stdout) and is_binary(stderr) do
    "pytest-output-v1\0" <>
      Integer.to_string(exit_code) <>
      "\0" <>
      Integer.to_string(byte_size(stdout)) <>
      "\0" <> stdout <> Integer.to_string(byte_size(stderr)) <> "\0" <> stderr
  end

  defp pytest_summary(stdout) do
    stdout
    |> String.split(~r/\R/)
    |> Enum.reverse()
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.trim()
  end

  defp expected(%{"comparison" => "matched", "expected" => expected}, _runtime), do: expected

  defp expected(%{"expected_by_runtime" => expected}, runtime),
    do: Map.fetch!(expected, runtime)

  defp imp_case_ids do
    ~w(
      continuous_root_transcript
      protected_context_alias
      persistent_context_versioning
      compaction_public_prompt_transition
      recursive_depth_boundary
      bounded_ordered_recursive_fanout
      expired_deadline_prevents_subcall
      local_code_capability
      assignment_before_cell_error
    )
  end

  defp static_lm(handler), do: %{module: Imp.LM.Static, opts: [handler: handler]}

  defp observe_imp_boundary(
         %{
           "kind" => "exported_call",
           "module" => module_name,
           "function" => function_name,
           "arity" => arity
         },
         fun
       )
       when is_function(fun, 0) do
    module = Module.concat(String.split(module_name, "."))
    function = String.to_existing_atom(function_name)
    {:module, ^module} = Code.ensure_loaded(module)
    exported = function_exported?(module, function, arity)

    if not exported do
      raise ArgumentError,
            "configured Imp boundary is not exported: #{module_name}.#{function_name}/#{arity}"
    end

    trace_pattern_matches = :erlang.trace_pattern({module, function, arity}, true, [])
    tracer = spawn(fn -> collect_trace_events([]) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()

      send(tracer, {:flush, self()})

      invocations =
        receive do
          {:rlm_trace_events, ^tracer, events} ->
            Enum.count(events, fn
              {:trace, _pid, :call, {^module, ^function, args}} when length(args) == arity -> true
              _event -> false
            end)
        after
          1_000 -> raise "timed out collecting Imp public boundary trace"
        end

      evidence = %{
        "mechanism" => "erlang_call_trace",
        "module" => module_name,
        "function" => function_name,
        "arity" => arity,
        "exported" => exported,
        "trace_pattern_matches" => trace_pattern_matches,
        "observed_invocations" => invocations
      }

      {result, evidence}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({module, function, arity}, false, [])
      send(tracer, :stop)
    end
  end

  defp observe_imp_boundary(_boundary, _fun),
    do: raise(ArgumentError, "invalid configured Imp boundary")

  defp collect_trace_events(events) do
    receive do
      {:trace, _pid, :call, _call} = event ->
        collect_trace_events([event | events])

      {:flush, caller} when is_pid(caller) ->
        send(caller, {:rlm_trace_events, self(), Enum.reverse(events)})
        collect_trace_events([])

      :stop ->
        :ok
    end
  end

  defp queued_lm(agent) do
    static_lm(fn _messages, _opts ->
      Agent.get_and_update(agent, fn
        [action | rest] -> {action, rest}
        [] -> raise "RLM differential controller queue exhausted"
      end)
    end)
  end

  defp controller_payload(messages),
    do: messages |> List.last() |> message_content() |> Jason.decode!()

  defp message_content(message),
    do: Map.get(message, :content, Map.get(message, "content", ""))

  defp message_role(message),
    do: message |> Map.get(:role, Map.get(message, "role", "unknown")) |> to_string()

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256(bytes) when is_binary(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
