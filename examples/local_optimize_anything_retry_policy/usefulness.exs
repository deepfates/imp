defmodule LocalOptimizeAnythingRetryPolicy.Usefulness do
  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}
  alias Imp.Optimizer.Artifact
  alias LocalOptimizeAnythingRetryPolicy.{ObservedLM, Task}

  @seeds [2_026_073_101, 2_026_073_102, 2_026_073_103]
  @test_path Path.join(__DIR__, "data/untouched-v2.jsonl")
  @test_sha "522245b0d7ec8d896c4b88c0475572a6325c2f25986d8b588d633bffa00590ff"
  @model "openrouter:anthropic/claude-sonnet-4.6"

  def run do
    test_rows = test_rows!()

    case System.get_env("IMP_88SN_MODE", "disabled") do
      "disabled" -> disabled!(test_rows)
      "preflight" -> catalog!()
      "live" -> Enum.each(@seeds, &live_seed(&1, test_rows))
      "fresh" -> fresh!(test_rows)
      mode -> raise "unknown IMP_88SN_MODE #{inspect(mode)}"
    end
  end

  defp disabled!(test_rows) do
    config = config(hd(@seeds), disabled_lm())
    true = length(Task.train()) == 8
    true = length(Task.selection()) == 6
    true = length(test_rows) == 6
    true = config.engine.max_candidate_proposals == 6
    true = config.reflection.module_selector == :round_robin

    IO.puts(
      Jason.encode!(%{
        status: "provider_disabled",
        seeds: @seeds,
        test_sha256: @test_sha,
        optimizer_transport_ceiling: 18
      })
    )
  end

  defp live_seed(seed, test_rows) do
    root = output_root!()
    seed_dir = Path.join(root, Integer.to_string(seed))
    File.mkdir_p!(seed_dir)
    refuse_existing!(seed_dir)

    traced =
      Imp.Observability.trace(fn ->
        Anything.run(Task.seed(), &Task.evaluate/2,
          dataset: Task.train(),
          valset: Task.selection(),
          objective:
            "Produce correct bounded retry delays: reject non-retryable work, honor server hints, retry urgent attempts zero and one immediately, then use capped exponential backoff.",
          background:
            "The artifact is a complete typed configuration. Every field is behaviorally evaluated; strict shape alone earns no reward.",
          config: config(seed, proposal_lm())
        )
      end)

    result = traced.result
    result_path = Path.join(seed_dir, "optimizer-result.json")
    artifact_path = Path.join(seed_dir, "selected-artifact.json")
    secure_write!(result_path, Jason.encode!(Result.to_map(result), pretty: true) <> "\n")

    artifact =
      Anything.to_artifact(result,
        provenance: %{
          "condition" => "imp-88sn-oa",
          "seed" => seed,
          "test_sha256" => @test_sha
        }
      )

    :ok = Artifact.write!(artifact, artifact_path)
    selected = artifact_path |> Artifact.read!() |> Artifact.value()

    baseline_test = evaluate(Task.seed(), test_rows)
    selected_test = evaluate(selected, test_rows)

    IO.puts(
      Jason.encode!(%{
        seed: seed,
        artifact_path: artifact_path,
        selected_candidate_id: Artifact.inspect(artifact).champion_id,
        proposer_generated: selected != Task.seed(),
        baseline_test: baseline_test,
        selected_test: selected_test,
        trace: Imp.Optimizer.Report.json_safe(traced.events)
      })
    )

    fresh_process!(seed, artifact_path, selected_test.outputs)
  end

  defp fresh!(test_rows) do
    artifact = System.fetch_env!("IMP_88SN_ARTIFACT") |> Artifact.read!()
    selected = Artifact.value(artifact)
    IO.puts(Jason.encode!(%{fresh: true, outputs: evaluate(selected, test_rows).outputs}))
  end

  defp fresh_process!(seed, artifact_path, expected_outputs) do
    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", Path.join(__DIR__, "run.exs")],
        cd: Path.expand("../..", __DIR__),
        env: [
          {"IMP_88SN_MODE", "fresh"},
          {"IMP_88SN_ARTIFACT", artifact_path}
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("OA seed #{seed} fresh process failed: #{output}")
    fresh = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    true = fresh["outputs"] == Jason.decode!(Jason.encode!(expected_outputs))
    IO.write(output)
  end

  defp evaluate(candidate, rows) do
    outputs =
      Enum.map(rows, fn row ->
        {score, info} = Task.evaluate(candidate, row)
        %{id: row.id, expected: row.expected, actual: info[:actual], score: score}
      end)

    %{
      exact_count: Enum.count(outputs, &(&1.score == 1.0)),
      proximity: Enum.sum(Enum.map(outputs, & &1.score)) / length(outputs),
      outputs: outputs
    }
  end

  defp config(seed, lm) do
    Config.new(
      engine: [
        max_candidate_proposals: 6,
        seed: seed,
        raise_on_exception: false,
        parallel: false,
        max_workers: 1,
        cache_evaluation: false,
        acceptance_criterion: :strict_improvement
      ],
      reflection: [
        reflection_lm: lm,
        module_selector: :round_robin,
        structured_response_format: :required
      ]
    )
  end

  defp proposal_lm do
    %ObservedLM{owner: self(), inner: remote_lm()}
  end

  defp remote_lm do
    Imp.req_llm(@model,
      api_key: System.fetch_env!("OPENROUTER_API_KEY"),
      cache: false,
      temperature: 1,
      max_tokens: 1024,
      max_retries: 0,
      timeout: 120_000,
      provider_options: provider_options(),
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp disabled_lm do
    Imp.LM.Static.new(handler: fn _messages, _opts -> raise "provider-disabled LM was called" end)
  end

  defp provider_options do
    [
      openrouter_provider: %{
        only: ["anthropic"],
        order: ["anthropic"],
        allow_fallbacks: false,
        require_parameters: true,
        data_collection: "deny",
        max_price: %{prompt: 3, completion: 15, request: 0}
      },
      openrouter_usage: %{include: true}
    ]
  end

  defp catalog! do
    body =
      Req.get!("https://openrouter.ai/api/v1/models/anthropic/claude-sonnet-4.6/endpoints",
        retry: false,
        max_retries: 0
      ).body

    true =
      Enum.any?(body["data"]["endpoints"], fn endpoint ->
        endpoint["provider_name"] == "Anthropic" and
          String.to_float(endpoint["pricing"]["prompt"]) == 0.000003 and
          String.to_float(endpoint["pricing"]["completion"]) == 0.000015
      end)

    IO.puts("OA route/privacy/price preflight passed")
  end

  defp test_rows! do
    true = file_sha256(@test_path) == @test_sha

    @test_path
    |> File.stream!()
    |> Enum.map(fn line ->
      row = Jason.decode!(line)

      %{
        id: row["id"],
        attempt: row["attempt"],
        retryable: row["retryable"],
        urgent: row["urgent"],
        retry_after_ms: row["retry_after_ms"],
        jitter_slot: row["jitter_slot"],
        expected: row["expected"]
      }
    end)
  end

  defp output_root!,
    do:
      System.get_env("IMP_88SN_OUTPUT", Path.join(System.tmp_dir!(), "imp-88sn-oa"))
      |> Path.expand()

  defp refuse_existing!(seed_dir) do
    if Path.wildcard(Path.join(seed_dir, "*")) != [],
      do: raise("output already exists: #{seed_dir}")
  end

  defp secure_write!(path, content) do
    io = File.open!(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, content)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp file_sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
