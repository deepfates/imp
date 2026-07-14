defmodule Imp.Optimizer.ArtifactTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{Artifact, GEPA.EvaluationCache.Codec, Report}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-optimizer-artifact-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "inspects, compares, applies, promotes, and rolls back without replacing runtime bindings",
       %{path: path} do
    live = runtime_program("baseline", "live-answer", api_key: "sk-live-credential-123456")
    champion = Artifact.candidate("baseline", optimized("baseline"), score: 0.4)

    report = Report.new(optimizer: :gepa, best_score: 0.9, candidate_count: 2)

    challenger =
      Artifact.candidate("candidate-1", optimized("improved"),
        score: 0.9,
        report: report,
        metadata: %{run_id: "run-1"}
      )

    artifact =
      Artifact.new(champion, [challenger], provenance: %{optimizer: "gepa", git_sha: "abc123"})

    assert :ok = Artifact.write!(artifact, path)
    loaded = Artifact.read!(path)

    assert %{
             champion_id: "baseline",
             challengers: ["candidate-1"],
             rollback_depth: 0,
             security: %{
               "credentials_absent" => true,
               "functions_absent" => true,
               "json_safe" => true
             }
           } = Artifact.inspect(loaded)

    assert %{
             score_delta: 0.5,
             changed_predictors: ["atom:main"]
           } = Artifact.compare(loaded, "baseline", "candidate-1")

    applied = Artifact.apply(loaded, live, "candidate-1")
    [predictor] = Imp.ProgramParameters.predictors(applied)
    assert predictor.predictor.signature.instructions == "improved"
    assert [%Imp.Example{}] = predictor.predictor.demos
    assert predictor.predictor.lm == live.predict.lm
    assert predictor.predictor.adapter == live.predict.adapter

    assert applied.predict.lm == live.predict.lm
    assert applied.predict.lm.opts[:api_key] == "sk-live-credential-123456"

    promoted = Artifact.promote(loaded, "candidate-1")

    assert %{champion_id: "candidate-1", rollback_depth: 1, revision: 2} =
             Artifact.inspect(promoted)

    rolled_back = Artifact.rollback(promoted)

    assert %{champion_id: "baseline", rollback_depth: 0, revision: 3} =
             Artifact.inspect(rolled_back)
  end

  test "strips credentials and rejects runtime functions" do
    program = runtime_program("safe", "answer", api_key: "sk-test-secret-123456789")

    candidate =
      Artifact.candidate("safe", program,
        metadata: %{
          api_key: "sk-metadata-secret-123456",
          nested: %{authorization: "Bearer abcdefghijklmnop"},
          note: "kept"
        }
      )

    artifact = Artifact.new(candidate, [], provenance: %{client_secret: "secret", owner: "team"})
    encoded = Jason.encode!(artifact)

    refute encoded =~ "sk-test"
    refute encoded =~ "sk-metadata"
    refute encoded =~ "authorization"
    refute encoded =~ "client_secret"
    refute encoded =~ "ReqLLMStub"
    assert encoded =~ "team"
    assert get_in(candidate, ["metadata", "note"]) == "kept"

    assert_raise ArgumentError, ~r/runtime functions|non-JSON/, fn ->
      Artifact.candidate("function", optimized("x"), metadata: %{callback: fn -> :ok end})
    end
  end

  test "registry-backed callbacks are names, never serialized functions" do
    metric = fn _example, _prediction -> true end
    registry = Imp.Saving.Registry.new(always_pass: metric)
    program = Imp.Predict.BestOfN.new(optimized("rank"), metric, n: 1)

    candidate = Artifact.candidate("ranked", program, registry: registry)
    artifact = Artifact.new(candidate)
    encoded = Jason.encode!(artifact)

    assert encoded =~ "always_pass"
    refute encoded =~ "#Function"

    assert %Imp.Predict.BestOfN{} =
             Artifact.apply(artifact, program, :champion, registry: registry)

    assert_raise ArgumentError, ~r/not present in the supplied saving registry/, fn ->
      Artifact.candidate("bad", program)
    end
  end

  test "rejects corruption, incompatible schemas, malformed envelopes, and impossible rollback" do
    artifact = Artifact.new(Artifact.candidate("base", optimized("base")))

    tampered =
      put_in(
        artifact,
        ["payload", "candidates", "base", "program", "signature", "instructions"],
        "evil"
      )

    assert_raise ArgumentError, ~r/checksum mismatch/, fn -> Artifact.inspect(tampered) end

    assert_raise ArgumentError, ~r/unsupported.*schema version/, fn ->
      artifact |> Map.put("schema_version", 99) |> Artifact.inspect()
    end

    assert_raise ArgumentError, ~r/unexpected or missing keys/, fn ->
      artifact |> Map.put("extra", true) |> Artifact.inspect()
    end

    assert_raise ArgumentError, ~r/no preserved champion/, fn -> Artifact.rollback(artifact) end

    incompatible = Imp.chain_of_thought("question -> answer, confidence: float")

    assert_raise ArgumentError, ~r/incompatible signature/, fn ->
      Artifact.apply(artifact, incompatible)
    end
  end

  test "rejects pre-canonical artifact schemas" do
    champion = Artifact.candidate("v1", optimized("legacy"))

    payload = %{
      "champion_id" => "v1",
      "candidates" => %{"v1" => champion},
      "provenance" => %{"source" => "legacy-run"}
    }

    legacy = %{
      "artifact_type" => "imp_optimizer_artifact",
      "schema_version" => 1,
      "payload_sha256" => Codec.checksum(payload),
      "payload" => payload
    }

    assert_raise ArgumentError, ~r/unsupported.*schema version/, fn ->
      Artifact.inspect(legacy)
    end
  end

  test "candidate predictor sets must match the target and no-op artifacts are rejected" do
    artifact = Artifact.new(Artifact.candidate("base", optimized("base")))

    assert_raise ArgumentError, ~r/predictor set is incompatible/, fn ->
      Artifact.apply(artifact, %Imp.Optimizer.Ensemble.Program{programs: []})
    end

    ensemble =
      Imp.Optimizer.Ensemble.new(deterministic: true)
      |> Imp.Optimizer.Ensemble.compile([optimized("nested")])

    assert_raise ArgumentError, ~r/expose at least one named predictor/, fn ->
      Artifact.candidate("no-lens", ensemble)
    end
  end

  defp optimized(instruction) do
    demo = Imp.example(question: "known", answer: "known") |> Imp.with_inputs(:question)

    Imp.chain_of_thought("question -> answer")
    |> Imp.ProgramParameters.put_instruction(:main, instruction)
    |> Imp.ProgramParameters.put_demos(:main, [demo])
  end

  defp runtime_program(instruction, answer, opts) do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: answer} end, api_key: opts[:api_key]]
    }

    Imp.chain_of_thought("question -> answer")
    |> Imp.ProgramParameters.put_instruction(:main, instruction)
    |> Imp.with_lm(lm)
  end
end
