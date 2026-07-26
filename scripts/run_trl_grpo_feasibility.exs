alias Imp.Clients.{TrainingJob, TRLArtifact, TRLLM, TRLProtocol, TRLTrainer}
alias Imp.Optimizer.TrainingResult

repo = File.cwd!()
cache_root = "/Users/deepfates/.cache/imp/trl/feasibility-v1"
python = Path.join(cache_root, ".venv/bin/python")
model_path = Path.join(cache_root, "model")
session_root = Path.join(cache_root, "sessions")
result_path = Path.join(repo, "benchmarks/results/local-trl-grpo-feasibility-20260725.json")
job_path = Path.join(cache_root, "job.json")
portable_path = Path.join(cache_root, "portable-program.json")
rebound_path = Path.join(cache_root, "fresh-rebound.json")
contract_path = Path.join(repo, "priv/trl_worker/feasibility-contract.json")
worker_key = {:trl_grpo_feasibility, 20_260_725}

atomic_write = fn path, value ->
  temporary = path <> ".tmp"
  File.mkdir_p!(Path.dirname(path))
  File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
  File.rename!(temporary, path)
end

source =
  repo
  |> Path.join("benchmarks/data/provider-training-banking77-v1.json")
  |> File.read!()
  |> Jason.decode!()

row = Enum.find(source["train"], &(&1["id"] == "banking77-train-2511"))

expected_row_sha =
  "sha256:dd5e7f7ca000bf4c92c81fe93b2b4fb3d05a52989a5cb8f2ab643f25f8242b91"

unless TRLProtocol.digest(Imp.Optimizer.Report.encode_term(row)) == expected_row_sha,
  do: raise("frozen Banking77 row identity mismatch")

signature =
  Imp.Signature.new(%{
    inputs: [%{name: :utterance, desc: "a real customer banking support request"}],
    outputs: [%{name: :route, desc: "exactly one opaque route: R17, R42, R68, or R93"}],
    instructions: """
    Classify the customer request into exactly one opaque route and return only that route.
    R17: a fee was charged for making a card payment.
    R42: a card payment is not recognized by the customer.
    R68: a card payment is still pending.
    R93: a card payment was reversed or reverted.
    """
  })

trainer =
  TRLTrainer.new(
    python: python,
    model_path: model_path,
    root: session_root,
    contract_path: contract_path,
    worker_key: worker_key,
    timeout: 900_000
  )

lm = %TRLLM{
  model: "Qwen/Qwen2.5-0.5B-Instruct@7ae557604adf67be50417f59c2c2f167def9a775",
  worker_key: worker_key,
  response_field: :route,
  timeout: 120_000
}

program = Imp.predict(signature, lm: lm)

example =
  Imp.example(
    utterance: row["utterance"],
    route: row["route"],
    source_id: row["id"]
  )
  |> Imp.with_inputs(:utterance)

optimizer =
  Imp.Optimizer.GRPO.new(
    fn expected, prediction ->
      if Imp.get(prediction, :route) == Imp.get(expected, :route), do: 1.0, else: 0.0
    end,
    trainer: trainer,
    num_train_steps: 1,
    num_dspy_examples_per_grpo_step: 1,
    num_rollouts_per_grpo_step: 4,
    seed: 20_260_725,
    status_poll_interval_ms: 0,
    callback_timeout_ms: 900_000,
    timeout: 120_000,
    checkpoint_path: Path.join(cache_root, "imp-grpo-checkpoint.bin")
  )

started_at = DateTime.utc_now() |> DateTime.to_iso8601()
{git_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

base_record = %{
  "schema_version" => 1,
  "scope" => "one real local MPS LoRA GRPO update feasibility only",
  "started_at" => started_at,
  "git_commit" => String.trim(git_head),
  "contract_sha256" => TRLProtocol.digest(Jason.decode!(File.read!(contract_path))),
  "row_id" => row["id"],
  "row_sha256" => expected_row_sha,
  "model" => lm.model
}

result =
  try do
    case Imp.train(program, optimizer, [example]) do
      {:ok,
       %TrainingResult{
         status: :completed,
         program: trained,
         job: %TrainingJob{status: :succeeded} = job
       }} ->
        {:ok, artifact} = TRLArtifact.verify_job(job)
        update = job.result_model |> Path.join("update-1.json") |> File.read!() |> Jason.decode!()

        observation =
          job.result_model |> Path.join("trl-observation.json") |> File.read!() |> Jason.decode!()

        portable = Imp.predict("utterance -> route", lm: Imp.req_llm("openai:portable-base"))
        :ok = TrainingJob.save!(job, job_path)
        :ok = Imp.save!(portable, portable_path)

        fresh_script = """
        job = Imp.Clients.TrainingJob.load!(#{inspect(job_path)})
        program = Imp.load!(#{inspect(portable_path)})
        {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, program, path: #{inspect(rebound_path)})
        IO.puts(Jason.encode!(%{
          model: Imp.ProgramAccess.lm(rebound).model,
          artifact_sha256: Imp.ProgramAccess.get_metadata(rebound, :training_artifact).artifact_sha256
        }))
        """

        {fresh_output, 0} =
          System.cmd(
            "mix",
            ["run", "--no-compile", "--no-deps-check", "-e", fresh_script],
            cd: repo,
            env: [{"MIX_ENV", "dev"}],
            stderr_to_stdout: true
          )

        fresh = fresh_output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

        unless fresh["model"] == job.result_model and
                 fresh["artifact_sha256"] == job.metadata.artifact_sha256,
               do: raise("fresh TrainingJob rebind identity mismatch")

        unless Registry.lookup(Imp.Clients.TRLWorker.Registry, worker_key) == [],
          do: raise("TRL worker remained registered after termination")

        %{
          "status" => "completed",
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "job" => %{
            "id" => job.id,
            "provider" => to_string(job.provider),
            "model" => job.model,
            "status" => to_string(job.status),
            "result_model" => job.result_model,
            "metadata" => Imp.Optimizer.Report.encode_term(job.metadata)
          },
          "artifact" => artifact,
          "observation" => observation,
          "samples" =>
            update["groups"]
            |> hd()
            |> Map.fetch!("samples")
            |> Enum.map(&Map.take(&1, ["position", "completion", "reward", "behavior_logprobs"])),
          "fresh_rebind" => fresh,
          "trained_program_model" => Imp.ProgramAccess.lm(trained).model,
          "worker_cleaned_up" => true
        }

      {:error, reason} ->
        %{
          "status" => "stopped",
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "reason" => inspect(reason),
          "worker_registered" => Registry.lookup(Imp.Clients.TRLWorker.Registry, worker_key) != []
        }
    end
  rescue
    error ->
      %{
        "status" => "stopped",
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "reason" => Exception.format(:error, error, __STACKTRACE__),
        "worker_registered" => Registry.lookup(Imp.Clients.TRLWorker.Registry, worker_key) != []
      }
  after
    case Registry.lookup(Imp.Clients.TRLWorker.Registry, worker_key) do
      [{worker, _}] -> Imp.Clients.TRLWorker.stop(worker)
      [] -> :ok
    end
  end

atomic_write.(result_path, Map.merge(base_record, result))
IO.puts("RESULT_PATH=" <> result_path)
IO.puts("STATUS=" <> result["status"])
