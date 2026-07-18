defmodule RagToolAgentArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tag :evidence_infrastructure
  test "RAG tool agent task writes a passing production-semantics artifact" do
    out_dir = tmp_dir("rag-tool-agent")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rag_tool_agent")
      Mix.Tasks.Imp.Benchmark.RagToolAgent.run(["--out", out_dir])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "rag-tool-agent-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert Mix.Tasks.Imp.Benchmark.RagToolAgent.validate_artifact!(artifact, require_clean: false) ==
             artifact

    if get_in(artifact, ["run_context", "workspace", "state"]) == "dirty" do
      assert_raise ArgumentError, ~r/requires a clean source checkout/, fn ->
        Mix.Tasks.Imp.Benchmark.RagToolAgent.validate_artifact!(artifact)
      end
    end

    assert get_in(artifact, ["run_context", "source_commits", "dspy"]) ==
             "stanfordnlp/dspy@29448ae12756abdd14bd8796c819247ebb83673c"

    assert get_in(artifact, ["run_context", "inputs", "task_sha256"]) =~ ~r/^sha256:/

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["provider_free_contract_complete"]
    refute artifact["summary"]["live_matched_behavior_complete"]
    refute artifact["summary"]["full_rag_tool_agent_parity"]
    assert artifact["summary"]["direct_comparisons"] == 2

    rows = Map.new(artifact["rows"], &{&1["id"], &1})

    assert rows["rag_memory_retrieval"]["passing"]

    assert get_in(rows, ["rag_memory_retrieval", "imp", "trace", "program"]) ==
             "Imp.Predict.RAG"

    assert rows["rag_multi_hop_retrieval"]["passing"]
    assert get_in(rows, ["rag_multi_hop_retrieval", "imp", "trace", "hops"]) |> length() == 2
    assert rows["react_lookup_tool"]["passing"]
    assert rows["code_act_tool_program"]["passing"]
    assert get_in(rows, ["code_act_tool_program", "imp", "trace"]) |> length() == 2
    assert rows["react_v2_recovers_from_tool_and_submit_errors"]["passing"]

    assert rows["react_v2_recovers_from_tool_and_submit_errors"]["imp"]["termination_reason"] ==
             "submit"
  end

  test "provider-free comparator rejects missing, duplicate, and wrong-source DSPy rows" do
    for {label, report} <- [
          {:missing, dspy_report([])},
          {:duplicate, dspy_report(provider_free_dspy_rows() ++ provider_free_dspy_rows())},
          {:wrong_source,
           dspy_report(provider_free_dspy_rows())
           |> put_in(["source", "commit"], String.duplicate("0", 40))}
        ] do
      out_dir = tmp_dir("rag-tool-agent-#{label}")

      assert_raise Mix.Error, ~r/(rows must be exactly|stale or wrong source)/, fn ->
        capture_io(fn ->
          Mix.Tasks.Imp.Benchmark.RagToolAgent.run_with_runners(["--out", out_dir], %{
            dspy: fn nil -> report end
          })
        end)
      end
    end
  end

  test "live mode admits only complete matched model behavior evidence" do
    out_dir = tmp_dir("rag-tool-agent-live")
    put_live_test_key()

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rag_tool_agent")

      Mix.Tasks.Imp.Benchmark.RagToolAgent.run_with_runners(live_args(out_dir), %{
        imp: fn config -> live_rows(config, config["model"]) end,
        dspy: fn config ->
          %{
            "runner" => "stub-dspy-live",
            "rows" => provider_free_dspy_rows() ++ live_rows(config, config["dspy_model"])
          }
        end
      })
    end)

    [path] = Path.wildcard(Path.join(out_dir, "rag-tool-agent-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["provider_free_contract_complete"]
    assert artifact["summary"]["live_matched_behavior_complete"]
    assert artifact["summary"]["full_rag_tool_agent_parity"]
    assert artifact["summary"]["total"] == 16
    assert artifact["summary"]["direct_comparisons"] == 4
  end

  test "live mode fails closed when generation controls differ" do
    out_dir = tmp_dir("rag-tool-agent-live-mismatch")
    put_live_test_key()

    assert_raise Mix.Error, ~r/RAG\/tool\/agent parity failed/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("imp.benchmark.rag_tool_agent")

        Mix.Tasks.Imp.Benchmark.RagToolAgent.run_with_runners(live_args(out_dir), %{
          imp: fn config -> live_rows(config, config["model"]) end,
          dspy: fn config ->
            mismatched =
              config
              |> live_rows(config["dspy_model"])
              |> Enum.map(fn row ->
                put_in(row, ["evidence", "generation", "max_tokens"], 401)
              end)

            %{
              "runner" => "stub-dspy-live-mismatch",
              "rows" => provider_free_dspy_rows() ++ mismatched
            }
          end
        })
      end)
    end

    [path] = Path.wildcard(Path.join(out_dir, "rag-tool-agent-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    refute artifact["summary"]["all_passing"]
    refute artifact["summary"]["live_matched_behavior_complete"]
    refute artifact["summary"]["full_rag_tool_agent_parity"]
  end

  test "live mode admits equivalent Anthropic Messages transports" do
    out_dir = tmp_dir("rag-tool-agent-live-anthropic")
    put_live_test_key()

    args =
      live_args(out_dir,
        model: "anthropic:claude-haiku-4-5-20251001",
        dspy_model: "anthropic/claude-haiku-4-5-20251001"
      )

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rag_tool_agent")

      Mix.Tasks.Imp.Benchmark.RagToolAgent.run_with_runners(args, %{
        imp: fn config -> live_rows(config, config["model"]) end,
        dspy: fn config ->
          %{
            "runner" => "stub-dspy-live",
            "rows" => provider_free_dspy_rows() ++ live_rows(config, config["dspy_model"])
          }
        end
      })
    end)

    [path] = Path.wildcard(Path.join(out_dir, "rag-tool-agent-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["summary"]["full_rag_tool_agent_parity"]
  end

  defp live_args(out_dir, overrides \\ []) do
    [
      "--out",
      out_dir,
      "--live",
      "--model",
      Keyword.get(overrides, :model, "gpt-5.4-mini-2026-03-17"),
      "--dspy-model",
      Keyword.get(overrides, :dspy_model, "responses/gpt-5.4-mini-2026-03-17"),
      "--api-key-env",
      "IMP_RAG_TOOL_AGENT_TEST_KEY"
    ]
  end

  defp put_live_test_key do
    previous = System.get_env("IMP_RAG_TOOL_AGENT_TEST_KEY")
    System.put_env("IMP_RAG_TOOL_AGENT_TEST_KEY", "test-key-not-sent")

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_RAG_TOOL_AGENT_TEST_KEY", previous),
        else: System.delete_env("IMP_RAG_TOOL_AGENT_TEST_KEY")
    end)
  end

  defp provider_free_dspy_rows do
    [
      %{"id" => "rag_memory_retrieval", "passing" => true, "answer" => "Paris"},
      %{
        "id" => "react_lookup_tool",
        "passing" => true,
        "answer" => "Paris",
        "tool_trace" => [
          %{
            "tool" => "lookup",
            "arguments" => %{"query" => "capital-france"},
            "result" => "Paris"
          }
        ]
      }
    ]
  end

  defp dspy_report(rows) do
    %{
      "runner" => "stub-dspy-provider-free",
      "rows" => rows,
      "source" => %{
        "repository" => "stanfordnlp/dspy",
        "version" => "3.2.1",
        "commit" => "29448ae12756abdd14bd8796c819247ebb83673c",
        "script_sha256" => sha256("scripts/dspy_rag_tool_agent.py"),
        "authority_sha256" => sha256("benchmarks/authority_sources/dspy-3.2.1-29448ae.json"),
        "fixture_sha256" => sha256("test/fixtures/benchmarks/rag-tool-agent-provider-free.json")
      }
    }
  end

  defp sha256(path) do
    "sha256:" <>
      (path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end

  defp live_rows(config, runtime_model) do
    evidence = %{
      "mode" => "live",
      "provider" => config["provider"],
      "model_identity" => config["model_identity"],
      "runtime_model" => runtime_model,
      "wire_api" =>
        if(String.starts_with?(runtime_model, "anthropic/"),
          do: "litellm_anthropic_messages",
          else: config["wire_api"]
        ),
      "generation" => config["settings"],
      "usage" => %{
        "requests" => 1,
        "input_tokens" => 10,
        "output_tokens" => 2,
        "usd" => 0.001
      },
      "usage_complete" => true,
      "error" => nil
    }

    rag_evidence =
      evidence
      |> Map.put("prompt_contract", "rag-exact-context-v1")
      |> Map.put("termination_tool", nil)

    tool_evidence =
      evidence
      |> Map.put("prompt_contract", "lookup-capital-then-terminate-v1")
      |> Map.put(
        "termination_tool",
        if(String.contains?(runtime_model, "/"), do: "finish", else: "submit")
      )

    [
      %{
        "id" => "live_rag_memory_retrieval",
        "category" => "rag",
        "passing" => true,
        "answer" => "Paris",
        "evidence" => rag_evidence
      },
      %{
        "id" => "live_mcp_lookup_tool",
        "category" => "tools",
        "passing" => true,
        "answer" => "Paris",
        "tool_trace" => [
          %{
            "tool" => "lookup_capital",
            "arguments" => %{"country" => "france"},
            "result" => "Paris"
          }
        ],
        "evidence" => tool_evidence
      }
    ]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
