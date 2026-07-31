defmodule Imp.ExperimentTest do
  use ExUnit.Case, async: false

  alias Imp.Experiment.{Data, Result}
  alias Imp.Optimizer.{Artifact, Report}

  defmodule SelectableOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:owner]

    @impl true
    def __optimizer__ do
      %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }
    end

    @impl true
    def run(%__MODULE__{owner: owner}, program, opts) do
      true = Keyword.has_key?(opts, :trainset)
      if owner, do: send(owner, {:optimizer_opts, opts})

      optimized =
        program
        |> Imp.ProgramParameters.put_instruction(:main, "Return the selected answer.")
        |> Report.attach(
          Report.new(
            optimizer: :instruction_search,
            best_score: 1.0,
            candidate_count: 2
          )
        )

      {:ok, optimized}
    end
  end

  defmodule MissingReportOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__ do
      %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }
    end

    @impl true
    def run(%__MODULE__{}, program, _opts) do
      {:ok, Imp.ProgramParameters.put_instruction(program, :main, "Return the selected answer.")}
    end
  end

  defmodule FailingOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__ do
      %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }
    end

    @impl true
    def run(%__MODULE__{}, _program, _opts), do: {:error, :deliberate_failure}
  end

  defmodule PretransportLM do
    defstruct [:owner]

    def generate(%__MODULE__{owner: owner}, messages, opts) do
      send(owner, {:pretransport_generate, messages, opts})

      {:error,
       {:request_validation_failed,
        %{api_key: "sk-provider-secret-should-not-leak", option: :unsupported_shape}}}
    end

    def response_format_capability(_lm), do: Imp.LM.Capability.none()
  end

  setup do
    root = Path.join(System.tmp_dir!(), "imp-experiment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "public lifecycle selects on validation, tests only the champion, and reloads the artifact",
       %{
         root: root
       } do
    owner = self()

    program =
      "question -> answer"
      |> Imp.signature("Return the baseline answer.")
      |> Imp.predict(lm: lm(owner))

    data =
      Data.new(
        train: [row("train-1", "train")],
        selection: [row("selection-1", "selection")],
        test: [row("test-1", "test")],
        id: :id
      )

    metric = Imp.exact_match(:answer)

    assert {:ok, result} =
             Imp.Experiment.check(program, %SelectableOptimizer{owner: owner}, data, metric,
               artifact_id: "selected-v1",
               optimizer_options: [custom_optimizer_control: :owned],
               evaluation_options: [max_concurrency: 1],
               compare_baseline_on_test: true
             )

    assert result.selected == :optimized
    assert result.baseline_selection.score == 0.0
    assert result.optimized_selection.score == 1.0
    assert result.baseline_test.score == 0.0
    assert result.test.score == 1.0
    assert Artifact.inspect(result.artifact).champion_id == "selected-v1"
    assert_received {:optimizer_opts, optimizer_opts}
    assert optimizer_opts[:custom_optimizer_control] == :owned
    refute Keyword.has_key?(optimizer_opts, :max_concurrency)

    assert_received {:call, "selection", false}
    assert_received {:call, "selection", true}
    assert_received {:call, "test", false}
    assert_received {:call, "test", true}
    refute_received {:call, "train", _selected?}

    result_path = Path.join(root, "result.json")
    artifact_path = Path.join(root, "artifact.json")
    :ok = Result.write!(result, result_path)
    :ok = Artifact.write!(result.artifact, artifact_path)

    assert %{
             "schema_version" => 2,
             "payload" => %{
               "selected" => "optimized",
               "status" => "completed",
               "baseline_test" => baseline_test
             }
           } =
             Result.read!(result_path)

    assert baseline_test["score"] == 0.0

    persisted = Jason.decode!(File.read!(result_path))
    encoded = File.read!(result_path)
    assert Bitwise.band(File.stat!(result_path).mode, 0o777) == 0o600
    refute encoded =~ "selection-1"
    refute encoded =~ "test-1"
    refute encoded =~ ~s("rows")
    assert persisted["payload"]["selection"]["baseline"]["row_count"] == 1

    detailed = Result.to_map(result, include_rows: true)
    assert detailed["payload"]["detail"] == "rows"
    assert length(detailed["payload"]["baseline_test"]["rows"]) == 1
    assert length(detailed["payload"]["test"]["rows"]) == 1

    legacy_path = Path.join(root, "legacy-result.json")
    legacy_payload = Map.delete(persisted["payload"], "baseline_test")

    legacy = %{
      persisted
      | "schema_version" => 1,
        "payload" => legacy_payload,
        "payload_sha256" => Data.digest(legacy_payload)
    }

    File.write!(legacy_path, Jason.encode!(legacy))
    assert %{"schema_version" => 1} = Result.read!(legacy_path)

    receipt_path = Path.join(root, "fresh-receipt.json")

    code = """
    stored = Imp.Experiment.Result.read!(#{inspect(result_path)})
    artifact = stored["payload"]["artifact"]
    lm = Imp.LM.Static.new(handler: fn messages, _opts ->
      rendered = Enum.map_join(messages, "\\n", & &1.content)
      %{answer: if(String.contains?(rendered, "Return the selected answer."), do: "yes", else: "no")}
    end)
    fresh = "question -> answer" |> Imp.signature("Fresh baseline.") |> Imp.predict(lm: lm)
    applied = Imp.Optimizer.Artifact.apply(artifact, fresh)
    {:ok, prediction} = Imp.call(applied, %{question: "fresh"})
    File.write!(#{inspect(receipt_path)}, Jason.encode!(%{
      answer: Imp.get(prediction, :answer),
      champion: Imp.Optimizer.Artifact.inspect(artifact).champion_id
    }))
    """

    assert {"", 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
               cd: File.cwd!(),
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert %{"answer" => "yes", "champion" => "selected-v1"} =
             receipt_path |> File.read!() |> Jason.decode!()

    tampered_path = Path.join(root, "tampered-result.json")

    tampered =
      result_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["payload", "selected"], "baseline")

    File.write!(tampered_path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/invalid Imp experiment result envelope/, fn ->
      Result.read!(tampered_path)
    end

    unknown_path = Path.join(root, "unknown-result.json")
    unknown = result_path |> File.read!() |> Jason.decode!()
    unknown_payload = Map.put(unknown["payload"], "untrusted", true)

    unknown =
      unknown
      |> Map.put("payload", unknown_payload)
      |> Map.put("payload_sha256", Data.digest(unknown_payload))

    File.write!(unknown_path, Jason.encode!(unknown))

    assert_raise ArgumentError, ~r/invalid Imp experiment result payload/, fn ->
      Result.read!(unknown_path)
    end
  end

  test "ordinary LabeledFewShot optimizer completes the public experiment lifecycle" do
    program =
      "ticket -> team: enum[atlas,harbor]"
      |> Imp.signature("Route each support ticket to its owning team.")
      |> Imp.predict(lm: routing_lm())

    data =
      Data.new(
        train: [
          routing_row("Duplicate invoice charge", "atlas"),
          routing_row("API outage in Europe", "harbor")
        ],
        selection: [
          routing_row("Refund the annual invoice", "atlas"),
          routing_row("Dashboard latency is spiking", "harbor")
        ],
        test: [
          routing_row("The monthly bill is wrong", "atlas"),
          routing_row("The service is unavailable", "harbor")
        ]
      )

    assert {:ok, result} =
             Imp.Experiment.check(
               program,
               Imp.Optimizer.LabeledFewShot.new(k: 2, sample: false),
               data,
               Imp.exact_match(:team)
             )

    assert result.selected == :optimized
    assert result.baseline_selection.score == 0.5
    assert result.optimized_selection.score == 1.0
    assert result.test.score == 1.0
    assert %Report{optimizer: "labeled_few_shot"} = Report.fetch(result.program)
    assert Artifact.inspect(result.artifact).champion_id == "optimized"

    fresh =
      "ticket -> team: enum[atlas,harbor]"
      |> Imp.signature("Fresh trusted router.")
      |> Imp.predict(lm: routing_lm())
      |> then(&Artifact.apply(result.artifact, &1))

    assert {:ok, prediction} = Imp.call(fresh, %{ticket: "The API is down"})
    assert Imp.get(prediction, :team) == "harbor"
  end

  test "split overlap fails before any optimizer or model call" do
    owner = self()
    row = row("same-source", "selection")

    assert_raise ArgumentError, ~r/identity-disjoint/, fn ->
      Data.new(train: [row], selection: [row], test: [row("test", "test")], id: :id)
    end

    refute_received _
    _program = Imp.predict("question -> answer", lm: lm(owner))
  end

  test "optimizer failure returns its stage without touching untouched test" do
    owner = self()
    program = Imp.predict("question -> answer", lm: lm(owner))

    data =
      Data.new(
        train: [row("train", "train")],
        selection: [row("selection", "selection")],
        test: [row("test", "test")],
        id: :id
      )

    assert {:error, %{stage: :optimize, reason: :deliberate_failure}} =
             Imp.Experiment.check(program, %FailingOptimizer{}, data, Imp.exact_match(:answer))

    assert_received {:call, "selection", false}
    refute_received {:call, "test", _selected?}
  end

  test "artifact failure occurs before any untouched-test call" do
    owner = self()

    program =
      "question -> answer"
      |> Imp.signature("Return the baseline answer.")
      |> Imp.predict(lm: lm(owner))

    data =
      Data.new(
        train: [row("train", "train")],
        selection: [row("selection", "selection")],
        test: [row("test", "test")],
        id: :id
      )

    assert {:error, %{stage: :artifact}} =
             Imp.Experiment.check(
               program,
               %MissingReportOptimizer{},
               data,
               Imp.exact_match(:answer)
             )

    assert_received {:call, "selection", false}
    assert_received {:call, "selection", true}
    refute_received {:call, "test", _selected?}
  end

  test "public check preserves a redacted structured row failure when evaluation cancels" do
    owner = self()

    program =
      "question -> answer"
      |> Imp.signature("Answer the question.")
      |> Imp.predict(
        lm: %PretransportLM{owner: owner},
        adapter: Imp.Adapter.Chat,
        config: [cache: false, json_fallback: false]
      )

    data =
      Data.new(
        train: [row("private-train-id", "train")],
        selection: [row("private-selection-id", "selection")],
        test: [row("private-test-id", "test")],
        id: :id
      )

    assert {:error,
            %{
              stage: :baseline_selection,
              exception: Imp.Experiment.StageError,
              reason: %{
                kind: :evaluation_cancelled,
                max_errors: 0,
                completed_rows: 1,
                failures: [failure]
              }
            } = returned} =
             Imp.Experiment.check(
               program,
               %SelectableOptimizer{owner: nil},
               data,
               Imp.exact_match(:answer),
               evaluation_options: [max_errors: 0]
             )

    assert failure.stage == :baseline_selection
    assert failure.index == 0
    assert is_binary(failure.identity_sha256)
    assert byte_size(failure.identity_sha256) == 64
    assert inspect(failure.reason) =~ "request_validation_failed"
    assert inspect(failure.reason) =~ "unsupported_shape"

    rendered = inspect(returned)
    refute rendered =~ "sk-provider-secret"
    refute rendered =~ "private-selection-id"
    refute rendered =~ "private-test-id"

    assert_received {:pretransport_generate, messages, settings}
    assert Enum.any?(messages, &(&1.role == :system))
    assert Enum.any?(messages, &(&1.role == :user))
    assert settings[:cache] == false
    refute Keyword.has_key?(settings, :json_fallback)
    refute_received {:optimizer_opts, _}
  end

  test "explicit infinite error budget retains ordered score-zero diagnostics" do
    owner = self()

    program =
      "question -> answer"
      |> Imp.signature("Answer the question.")
      |> Imp.predict(
        lm: %PretransportLM{owner: owner},
        adapter: Imp.Adapter.Chat,
        config: [cache: false, json_fallback: false]
      )

    data =
      Data.new(
        train: [row("train-id", "train")],
        selection: [row("selection-id", "selection")],
        test: [row("test-id", "test")],
        id: :id
      )

    assert {:ok, result} =
             Imp.Experiment.check(
               program,
               %SelectableOptimizer{owner: nil},
               data,
               Imp.exact_match(:answer),
               evaluation_options: [
                 failure_score: 0.0,
                 max_concurrency: 1,
                 max_errors: :infinity
               ]
             )

    assert result.selected == :baseline
    assert result.baseline_selection.score == 0.0
    assert result.optimized_selection.score == 0.0
    assert result.test.score == 0.0

    assert [%{index: 0, reason: {:request_validation_failed, _}}] =
             result.baseline_selection.errors

    assert [%{index: 0, reason: {:request_validation_failed, _}}] =
             result.optimized_selection.errors

    assert [%{index: 0, reason: {:request_validation_failed, _}}] = result.test.errors
    assert length(result.baseline_selection.rows) == 1
    assert length(result.optimized_selection.rows) == 1
    assert length(result.test.rows) == 1
    assert_received {:pretransport_generate, _, _}
  end

  test "custom identities remain private while row contents stay content-bound" do
    first =
      Data.new(
        train: [row("source-train", "first train")],
        selection: [row("source-selection", "first selection")],
        test: [row("source-test", "first test")],
        id: :id
      )

    second =
      Data.new(
        train: [row("source-train", "changed train")],
        selection: [row("source-selection", "first selection")],
        test: [row("source-test", "first test")],
        id: :id
      )

    first_manifest = Data.manifest(first)
    second_manifest = Data.manifest(second)
    refute inspect(first_manifest) =~ "source-train"
    assert first_manifest["identity_sha256"] == second_manifest["identity_sha256"]
    refute first_manifest["row_sha256"]["train"] == second_manifest["row_sha256"]["train"]
  end

  defp row(id, question) do
    Imp.example(id: id, question: question, answer: "yes") |> Imp.with_inputs(:question)
  end

  defp routing_row(ticket, team) do
    Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
  end

  defp routing_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        query =
          messages
          |> Enum.filter(&(&1.role == :user))
          |> List.last()
          |> Map.fetch!(:content)

        has_demos? = Enum.any?(messages, &(&1.role == :assistant))

        team =
          if has_demos? and
               String.contains?(query, ["latency", "unavailable", "outage", "API", "service"]) do
            "harbor"
          else
            "atlas"
          end

        %{team: team}
      end
    )
  end

  defp lm(owner) do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\n", & &1.content)
        selected? = String.contains?(rendered, "Return the selected answer.")

        phase =
          cond do
            String.contains?(rendered, "selection") -> "selection"
            String.contains?(rendered, "test") -> "test"
            String.contains?(rendered, "train") -> "train"
            true -> "fresh"
          end

        send(owner, {:call, phase, selected?})
        %{answer: if(selected?, do: "yes", else: "no")}
      end
    )
  end
end
