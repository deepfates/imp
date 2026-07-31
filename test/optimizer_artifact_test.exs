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
             changed_predictors: ["main"]
           } = Artifact.compare(loaded, "baseline", "candidate-1")

    applied = Artifact.apply(loaded, live, "candidate-1")
    [predictor] = Imp.ProgramParameters.predictors(applied)
    assert predictor.predictor.signature.instructions == "improved"
    assert [%Imp.Example{}] = predictor.predictor.demos
    assert predictor.predictor.lm == live.predict.lm
    assert predictor.predictor.adapter == live.predict.adapter

    assert %Report{
             optimizer: "gepa",
             best_score: 0.9,
             candidate_count: 2,
             candidates: [],
             errors: [],
             metadata: %{}
           } = Report.fetch(applied)

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
    # Corrected toward loudness (dee-i3s4 / P03): a candidate whose program
    # pins a non-portable runtime LM now fails loudly at dump time instead of
    # silently stripping the LM into a contradictory artifact — the pinned
    # credential can never reach the artifact at all.
    assert_raise ArgumentError, ~r/Predict LM is not portable/, fn ->
      Artifact.candidate(
        "safe",
        runtime_program("safe", "answer", api_key: "sk-test-secret-123456789")
      )
    end

    candidate =
      Artifact.candidate("safe", optimized("safe"),
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

  test "candidate reports drop atom-key credentials before tagged JSON encoding" do
    canaries = %{
      api_key: "CANARY_ARTIFACT_ATOM_API_KEY_7e31d",
      authorization: "CANARY_ARTIFACT_ATOM_AUTHORIZATION_51bc9",
      provider_auth: "CANARY_ARTIFACT_PROVIDER_AUTH_f208a",
      provider_session: "CANARY_ARTIFACT_PROVIDER_SESSION_9d14e"
    }

    report =
      Report.new(
        optimizer: :bootstrap_few_shot,
        candidate_count: 1,
        candidates: [
          %{
            api_key: canaries.api_key,
            nested: %{authorization: canaries.authorization},
            label: "retained-candidate"
          }
        ],
        metadata: %{providerAuth: canaries.provider_auth, scope: "retained-scope"}
      )

    candidate = Artifact.candidate("tagged-report", optimized("safe"), report: report)
    candidate_json = Jason.encode!(candidate)

    Enum.each(canaries, fn {_name, canary} -> refute candidate_json =~ canary end)
    refute candidate_json =~ "api_key"
    refute candidate_json =~ "authorization"
    refute candidate_json =~ "providerAuth"

    sanitized_report = Report.load(candidate["report"])
    assert sanitized_report.candidates == [%{label: "retained-candidate", nested: %{}}]
    assert sanitized_report.metadata == %{scope: "retained-scope"}

    artifact =
      Artifact.new(candidate, [],
        provenance: %{providerSession: canaries.provider_session, owner: "retained-owner"}
      )

    assert artifact["payload"]["security"]["credentials_absent"]
    assert artifact["payload"]["provenance"] == %{"owner" => "retained-owner"}

    artifact_json = Jason.encode!(artifact)
    Enum.each(canaries, fn {_name, canary} -> refute artifact_json =~ canary end)
  end

  test "malformed typed credential keys cannot contradict the artifact security proof" do
    typed_key = %{"__imp_type__" => "atom", "value" => "api_key", "extra" => "bypass"}

    report = Report.new(metadata: %{typed_key => "CANARY_TYPED_KEY_SECRET"})
    candidate = Artifact.candidate("typed-key", optimized("safe"), report: report)
    artifact = Artifact.new(candidate)
    encoded = Jason.encode!(artifact)

    refute encoded =~ "CANARY_TYPED_KEY_SECRET"
    assert artifact["payload"]["security"]["credentials_absent"]
    assert Report.load(candidate["report"]).metadata == %{}
  end

  test "mixed tagged envelope collisions cannot contradict the artifact security proof" do
    typed_key = %{"__imp_type__" => "atom", "value" => "api_key"}

    hostile =
      Map.new([
        {:__imp_type__, "noop"},
        {"__imp_type__", "map"},
        {:entries, [[typed_key, "CANARY_COLLISION_SECRET"]]},
        {"entries", []}
      ])

    assert_raise ArgumentError, ~r/collide after JSON normalization/, fn ->
      Artifact.candidate("collision", optimized("safe"), metadata: hostile)
    end
  end

  test "semantic credential-named schema fields survive artifact normalization" do
    candidate =
      Artifact.candidate("schema", optimized("safe"),
        metadata: %{schema: %{token: :string, api_key: :string, name: :string}}
      )

    assert candidate["metadata"]["schema"] == %{
             "token" => "string",
             "api_key" => "string",
             "name" => "string"
           }
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

  test "applies optimizer-owned output prefix changes without weakening the field contract" do
    baseline = optimized("baseline")

    selected =
      baseline
      |> Imp.ProgramParameters.put_instruction(:main, "selected")
      |> put_output_prefix("_selected_answer")
      |> Imp.Optimizer.Report.attach(
        Report.new(optimizer: :copro, best_score: 0.8, candidate_count: 2)
      )

    artifact = Artifact.from_optimized_program(selected)
    applied = Artifact.apply(artifact, baseline)
    [predictor] = Imp.ProgramParameters.predictors(applied)

    assert predictor.predictor.signature.instructions == "selected"
    assert List.last(predictor.predictor.signature.outputs).prefix == "_selected_answer"

    incompatible =
      Imp.ProgramParameters.update_predictor(baseline, :main, fn predictor ->
        outputs =
          List.update_at(predictor.signature.outputs, -1, fn output ->
            %{output | type: :integer}
          end)

        signature = %{predictor.signature | outputs: outputs}
        Imp.Predict.Predict.with_signature(predictor, signature)
      end)

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

  test "value candidates are portable data and schema-2 program artifacts remain compatible",
       %{path: path} do
    value = %{"enabled" => true, "retries" => 3, "labels" => ["fast", "safe"]}
    value_artifact = Artifact.new(Artifact.value_candidate("selected", value, score: 1.0))
    :ok = Artifact.write!(value_artifact, path)
    assert Artifact.value(Artifact.read!(path)) == value

    assert_raise ArgumentError, ~r/use value\/2 instead/, fn ->
      Artifact.apply(value_artifact, optimized("trusted"))
    end

    assert_raise ArgumentError, ~r/canonical JSON/, fn ->
      Artifact.value_candidate("unsafe", %{consumer_key: :consumer_value})
    end

    current =
      Artifact.new(
        Artifact.candidate("baseline", optimized("legacy"), score: 0.25),
        [Artifact.candidate("selected", optimized("selected"), score: 0.75)]
      )

    legacy_candidates =
      Map.new(current["payload"]["candidates"], fn {id, candidate} ->
        {id, Map.delete(candidate, "kind")}
      end)

    payload = %{current["payload"] | "candidates" => legacy_candidates}

    legacy = %{
      "artifact_type" => "imp_optimizer_artifact",
      "schema_version" => 2,
      "payload_sha256" => Codec.checksum(payload),
      "payload" => payload
    }

    assert %{schema_version: 2, champion_id: "baseline"} = Artifact.inspect(legacy)
    assert Artifact.apply(legacy, optimized("fresh")).predict.signature.instructions == "legacy"

    assert %{score_delta: 0.5, changed_predictors: ["main"]} =
             Artifact.compare(legacy, "baseline", "selected")

    promoted = Artifact.promote(legacy, "selected")
    assert %{schema_version: 2, champion_id: "selected", revision: 2} = Artifact.inspect(promoted)

    assert %{champion_id: "baseline", revision: 3} =
             promoted |> Artifact.rollback() |> Artifact.inspect()
  end

  test "legacy artifact identifiers stay strings and resolve against a trusted live program" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    predictor_name = "artifact_unseen_predictor_" <> suffix
    report_identifier = "artifact_unseen_report_identifier_" <> suffix

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(predictor_name, :utf8)
    end

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(report_identifier, :utf8)
    end

    baseline =
      Imp.Optimizer.Artifact.ParameterSnapshot.new([
        %{name: predictor_name, predictor: Imp.predict("question -> answer")}
      ])

    selected =
      Imp.ProgramParameters.put_instruction(
        baseline,
        predictor_name,
        "Selected portable instruction."
      )

    candidate =
      Artifact.candidate("selected", selected,
        report: Report.new(optimizer: "placeholder", best_score: 1.0, candidate_count: 1)
      )

    legacy_name = %{"__imp_type__" => "atom", "value" => predictor_name}

    candidate =
      candidate
      |> put_in(["program", "predictors", Access.at(0), "name"], legacy_name)
      |> put_in(
        ["report", "optimizer"],
        %{"__imp_type__" => "atom", "value" => report_identifier}
      )
      |> then(
        &Map.put(
          &1,
          "program_sha256",
          Codec.checksum(&1["program"])
        )
      )

    artifact = Artifact.new(candidate)
    applied = Artifact.apply(artifact, baseline)

    assert [%{name: ^predictor_name, predictor: predictor}] =
             Imp.ProgramParameters.predictors(applied)

    assert predictor.signature.instructions == "Selected portable instruction."
    assert %Report{optimizer: ^report_identifier} = Report.load_portable(candidate["report"])

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(predictor_name, :utf8)
    end

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(report_identifier, :utf8)
    end
  end

  defp optimized(instruction) do
    demo = Imp.example(question: "known", answer: "known") |> Imp.with_inputs(:question)

    Imp.chain_of_thought("question -> answer")
    |> Imp.ProgramParameters.put_instruction(:main, instruction)
    |> Imp.ProgramParameters.put_demos(:main, [demo])
  end

  defp put_output_prefix(program, prefix) do
    Imp.ProgramParameters.update_predictor(program, :main, fn predictor ->
      outputs =
        List.update_at(predictor.signature.outputs, -1, fn output ->
          %{output | prefix: prefix}
        end)

      Imp.Predict.Predict.with_signature(predictor, %{predictor.signature | outputs: outputs})
    end)
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
