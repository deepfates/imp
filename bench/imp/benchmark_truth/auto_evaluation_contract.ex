defmodule Imp.BenchmarkTruth.AutoEvaluationContract do
  @moduledoc false

  alias Imp.BenchmarkTruth.{ArtifactFile, RunContext}
  alias Imp.Evaluate.{CompleteAndGrounded, SemanticF1}

  @default_manifest "benchmarks/config/auto-evaluation-differential-v1.json"
  @authority %{
    "repository" => "https://github.com/stanfordnlp/dspy",
    "version" => "3.2.1",
    "commit" => "29448ae12756abdd14bd8796c819247ebb83673c",
    "source" =>
      "dspy/evaluate/auto_evaluation.py#sha256=fc902532e25c243161a351e0765c61140eda06128845320259e833a378838339",
    "test" =>
      "tests/evaluate/test_auto_evaluation.py#sha256=2ee33255d3de75dce4dbb41ce2cfe6abd277644903203f8a4370d87b78af1467"
  }
  @case_ids ~w(
    semantic_direct_harmonic_mean
    semantic_trace_threshold
    semantic_decompositional_contract
    semantic_clamped_helper
    complete_grounded_independent_trace
    complete_grounded_zero_direct
  )

  def default_manifest, do: @default_manifest

  def load_manifest!(path \\ @default_manifest) do
    bytes = File.read!(path)
    manifest = Jason.decode!(bytes)
    validate_manifest!(manifest)
    Map.put(manifest, "sha256", sha256(bytes))
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid auto-evaluation differential manifest #{Path.expand(path)}: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def validate_manifest!(manifest) do
    cases = Map.fetch!(manifest, "cases")

    valid? =
      exact_keys?(manifest, ~w(schema_version id authority claim_scope cases)) and
        manifest["schema_version"] == 1 and
        manifest["id"] == "dspy-3.2.1-auto-evaluation-provider-free-differential" and
        manifest["authority"] == @authority and
        manifest["claim_scope"] ==
          "provider-free behavioral differential for deterministic DSPy 3.2.1 auto-evaluation semantics" and
        is_list(cases) and Enum.map(cases, & &1["id"]) == @case_ids and
        Enum.all?(cases, &valid_case?/1)

    if valid?, do: manifest, else: raise(ArgumentError, "manifest contract does not match v1")
  end

  def run!(opts) do
    manifest_path = Keyword.get(opts, :manifest, @default_manifest)
    manifest = load_manifest!(manifest_path)
    rows = Enum.map(manifest["cases"], &run_case!/1)

    context =
      RunContext.capture_git!(
        cwd: Keyword.get(opts, :cwd, File.cwd!()),
        require_clean: not Keyword.get(opts, :allow_dirty, false),
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@authority["commit"]}"},
        inputs: %{
          "protocol_id" => "auto_evaluation_contract",
          "manifest" => %{
            "path" => Path.relative_to_cwd(Path.expand(manifest_path)),
            "sha256" => manifest["sha256"]
          }
        }
      )

    artifact = %{
      "schema_version" => 1,
      "evidence_tier" => "t1_dspy_3_2_1_auto_evaluation_differential",
      "claim_scope" => manifest["claim_scope"],
      "authority" => @authority,
      "manifest" => %{
        "id" => manifest["id"],
        "path" => Path.relative_to_cwd(Path.expand(manifest_path)),
        "sha256" => manifest["sha256"]
      },
      "runtime" => %{"provider_calls" => 0, "network_calls" => 0},
      "rows" => rows,
      "summary" => %{
        "required_cases" => length(@case_ids),
        "passing_cases" => Enum.count(rows, & &1["passing"]),
        "contract_complete" => Enum.all?(rows, & &1["passing"]),
        "natural_data_quality" => false,
        "provider_calls" => 0
      }
    }

    result = ArtifactFile.write_run_json!(Keyword.fetch!(opts, :output), artifact, context)
    validate_artifact!(result.artifact, manifest_path)
    result
  end

  def validate_artifact!(artifact, manifest_path \\ @default_manifest) do
    RunContext.verify!(artifact)
    manifest = load_manifest!(manifest_path)
    expected_rows = Enum.map(manifest["cases"], &run_case!/1)
    summary = artifact["summary"] || %{}

    valid? =
      artifact["schema_version"] == 1 and
        artifact["evidence_tier"] == "t1_dspy_3_2_1_auto_evaluation_differential" and
        artifact["claim_scope"] == manifest["claim_scope"] and artifact["authority"] == @authority and
        artifact["manifest"] == %{
          "id" => manifest["id"],
          "path" => Path.relative_to_cwd(Path.expand(manifest_path)),
          "sha256" => manifest["sha256"]
        } and artifact["runtime"] == %{"provider_calls" => 0, "network_calls" => 0} and
        artifact["rows"] == expected_rows and summary["required_cases"] == length(@case_ids) and
        summary["passing_cases"] == length(@case_ids) and summary["contract_complete"] == true and
        summary["natural_data_quality"] == false and summary["provider_calls"] == 0 and
        get_in(artifact, ["run_context", "source_commits", "dspy"]) ==
          "stanfordnlp/dspy@#{@authority["commit"]}"

    if valid?,
      do: artifact,
      else: raise(ArgumentError, "invalid auto-evaluation differential artifact")
  end

  defp run_case!(%{"evaluator" => "semantic_f1_score"} = spec) do
    judgments = spec["judgments"]
    {:ok, score} = SemanticF1.f1_score(judgments["precision"], judgments["recall"])
    row(spec, score, score, 0, [])
  end

  defp run_case!(%{"evaluator" => "semantic_f1"} = spec) do
    parent = self()
    lm = scripted_lm(parent, spec)

    evaluator =
      SemanticF1.new(
        lm: lm,
        threshold: spec["threshold"],
        decompositional: spec["decompositional"]
      )

    {:ok, result} = SemanticF1.call(evaluator, inputs(spec))
    prompts = collect_prompts(spec["expected"]["judge_calls"], [])
    row(spec, Imp.Prediction.get(result, :f1), result.score, length(prompts), prompts)
  end

  defp run_case!(%{"evaluator" => "complete_and_grounded"} = spec) do
    parent = self()

    evaluator =
      CompleteAndGrounded.new(lm: scripted_lm(parent, spec), threshold: spec["threshold"])

    {:ok, result} = CompleteAndGrounded.call(evaluator, inputs(spec))
    prompts = collect_prompts(spec["expected"]["judge_calls"], [])
    row(spec, Imp.Prediction.get(result, :f1), result.score, length(prompts), prompts)
  end

  defp row(spec, f1, score, calls, prompts) do
    expected = spec["expected"]

    checks = %{
      "f1" => close?(f1, expected["f1"]),
      "score" => equivalent?(score, expected["score"]),
      "judge_calls" => calls == expected["judge_calls"],
      "prompt_contract" => prompt_contract?(spec, prompts)
    }

    %{
      "id" => spec["id"],
      "evaluator" => spec["evaluator"],
      "expected" => expected,
      "actual" => %{"f1" => f1, "score" => score, "judge_calls" => calls},
      "checks" => checks,
      "passing" => Enum.all?(checks, fn {_name, passing} -> passing end)
    }
  end

  defp scripted_lm(parent, spec) do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        prompt = Enum.map_join(messages, "\n", & &1.content)
        send(parent, {:auto_evaluation_prompt, prompt})
        judgment(spec, prompt)
      end
    )
  end

  defp judgment(%{"evaluator" => "semantic_f1"} = spec, _prompt) do
    base = %{
      reasoning: "provider-free scripted judgment",
      precision: spec["judgments"]["precision"],
      recall: spec["judgments"]["recall"]
    }

    if spec["decompositional"] do
      Map.merge(base, %{
        ground_truth_key_ideas: "gold idea",
        system_response_key_ideas: "response idea",
        discussion: "scripted overlap"
      })
    else
      base
    end
  end

  defp judgment(%{"evaluator" => "complete_and_grounded"} = spec, prompt) do
    if String.contains?(prompt, "completeness") do
      %{
        reasoning: "provider-free completeness judgment",
        ground_truth_key_ideas: "gold idea",
        system_response_key_ideas: "response idea",
        discussion: "scripted completeness",
        completeness: spec["judgments"]["completeness"]
      }
    else
      %{
        reasoning: "provider-free groundedness judgment",
        system_response_claims: "response claim",
        discussion: "scripted grounding",
        groundedness: spec["judgments"]["groundedness"]
      }
    end
  end

  defp inputs(%{"input_shape" => "example_prediction"} = spec) do
    maybe_trace(
      %{
        example: Imp.example(question: "What is the answer?", response: "gold answer"),
        pred: Imp.prediction(response: "system answer", context: "retrieved context")
      },
      spec["trace"]
    )
  end

  defp inputs(spec) do
    maybe_trace(
      %{
        question: "What is the answer?",
        ground_truth: "gold answer",
        system_response: "system answer",
        retrieved_context: "retrieved context"
      },
      spec["trace"]
    )
  end

  defp maybe_trace(inputs, true), do: Map.put(inputs, :trace, :optimizer)
  defp maybe_trace(inputs, false), do: inputs

  defp collect_prompts(0, acc), do: Enum.reverse(acc)

  defp collect_prompts(count, acc) do
    receive do
      {:auto_evaluation_prompt, prompt} -> collect_prompts(count - 1, [prompt | acc])
    after
      1_000 -> raise "auto-evaluation scripted judge did not complete"
    end
  end

  defp prompt_contract?(%{"evaluator" => "semantic_f1_score"}, []), do: true

  defp prompt_contract?(%{"evaluator" => "semantic_f1", "decompositional" => true}, [prompt]) do
    String.contains?(prompt, "ground_truth_key_ideas") and
      String.contains?(prompt, "system_response_key_ideas")
  end

  defp prompt_contract?(%{"evaluator" => "semantic_f1"}, [prompt]) do
    String.contains?(prompt, "precision") and String.contains?(prompt, "recall")
  end

  defp prompt_contract?(%{"evaluator" => "complete_and_grounded"}, prompts) do
    length(prompts) == 2 and Enum.count(prompts, &String.contains?(&1, "completeness")) == 1 and
      Enum.count(prompts, &String.contains?(&1, "groundedness")) == 1 and
      Enum.any?(prompts, &String.contains?(&1, "retrieved_context"))
  end

  defp prompt_contract?(_spec, _prompts), do: false

  defp valid_case?(%{"evaluator" => "semantic_f1_score"} = spec) do
    exact_keys?(spec, ~w(id evaluator judgments expected)) and valid_judgments?(spec) and
      valid_expected?(spec) and oracle_expected?(spec)
  end

  defp valid_case?(%{"evaluator" => evaluator} = spec)
       when evaluator in ~w(semantic_f1 complete_and_grounded) do
    required =
      if evaluator == "semantic_f1",
        do: ~w(id evaluator input_shape decompositional trace threshold judgments expected),
        else: ~w(id evaluator input_shape trace threshold judgments expected)

    exact_keys?(spec, required) and spec["input_shape"] in ~w(direct example_prediction) and
      is_boolean(spec["trace"]) and is_number(spec["threshold"]) and valid_judgments?(spec) and
      valid_expected?(spec) and oracle_expected?(spec)
  end

  defp valid_case?(_spec), do: false

  defp valid_judgments?(%{"evaluator" => evaluator, "judgments" => judgments})
       when evaluator in ~w(semantic_f1 semantic_f1_score) do
    exact_keys?(judgments, ~w(precision recall)) and
      Enum.all?(Map.values(judgments), &is_number/1)
  end

  defp valid_judgments?(%{"judgments" => judgments}) do
    exact_keys?(judgments, ~w(completeness groundedness)) and
      Enum.all?(Map.values(judgments), &is_number/1)
  end

  defp valid_expected?(%{"expected" => expected}) do
    exact_keys?(expected, ~w(f1 score judge_calls)) and is_number(expected["f1"]) and
      (is_number(expected["score"]) or is_boolean(expected["score"])) and
      is_integer(expected["judge_calls"]) and expected["judge_calls"] >= 0
  end

  defp oracle_expected?(%{"evaluator" => evaluator} = spec)
       when evaluator in ~w(semantic_f1 semantic_f1_score) do
    expected = spec["expected"]
    judgments = spec["judgments"]
    f1 = oracle_f1(judgments["precision"], judgments["recall"])
    calls = if evaluator == "semantic_f1", do: 1, else: 0

    close?(expected["f1"], f1) and equivalent?(expected["score"], oracle_score(spec, f1)) and
      expected["judge_calls"] == calls
  end

  defp oracle_expected?(%{"evaluator" => "complete_and_grounded"} = spec) do
    expected = spec["expected"]
    judgments = spec["judgments"]
    f1 = oracle_f1(judgments["groundedness"], judgments["completeness"])

    close?(expected["f1"], f1) and equivalent?(expected["score"], oracle_score(spec, f1)) and
      expected["judge_calls"] == 2
  end

  defp oracle_score(%{"trace" => true, "threshold" => threshold}, f1), do: f1 >= threshold
  defp oracle_score(_spec, f1), do: f1

  defp oracle_f1(left, right) do
    left = min(max(left * 1.0, 0.0), 1.0)
    right = min(max(right * 1.0, 0.0), 1.0)
    if left + right == 0.0, do: 0.0, else: 2.0 * left * right / (left + right)
  end

  defp exact_keys?(map, keys), do: map |> Map.keys() |> Enum.sort() == Enum.sort(keys)
  defp equivalent?(left, right) when is_number(left) and is_number(right), do: close?(left, right)
  defp equivalent?(left, right), do: left === right
  defp close?(left, right), do: abs(left - right) <= 1.0e-12
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
