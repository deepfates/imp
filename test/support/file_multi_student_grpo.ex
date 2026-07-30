defmodule Imp.Test.MultiStudentGRPOLM do
  @moduledoc false
  @behaviour Imp.LM

  defstruct [:model, :output]

  @impl true
  def generate(_messages, _opts), do: {:error, :multi_student_lm_instance_required}

  def generate(%__MODULE__{output: output}, _messages, _opts), do: {:ok, output}
end

defmodule Imp.Test.MultiStudentGRPOProgram do
  @moduledoc false
  @behaviour Imp.Module

  defstruct [:first, :second]

  def new(opts \\ []) do
    second_model = Keyword.get(opts, :second_model, "fresh-base-b")

    %__MODULE__{
      first:
        Imp.predict("question -> first_answer",
          lm: %Imp.Test.MultiStudentGRPOLM{
            model: "fresh-base-a",
            output: %{first_answer: "one"}
          }
        ),
      second:
        Imp.predict("question -> second_answer",
          lm: %Imp.Test.MultiStudentGRPOLM{
            model: second_model,
            output: %{second_answer: "two"}
          }
        )
    }
  end

  @impl true
  def optimizer_predictors(program), do: [first: program.first, second: program.second]

  @impl true
  def update_optimizer_predictor(program, :first, update),
    do: %{program | first: update.(program.first)}

  def update_optimizer_predictor(program, :second, update),
    do: %{program | second: update.(program.second)}

  @impl true
  def call(program, inputs) do
    with {:ok, first} <- Imp.Module.call(program.first, inputs),
         {:ok, second} <- Imp.Module.call(program.second, inputs) do
      {:ok,
       Imp.Prediction.new(Map.merge(Imp.Prediction.to_map(first), Imp.Prediction.to_map(second)))}
    end
  end

  def save!(%__MODULE__{} = program, path) do
    payload = :erlang.term_to_binary(program, [:deterministic])

    artifact = %{
      "type" => "imp_test_multi_student_grpo_program",
      "schema_version" => 1,
      "payload" => Base.encode64(payload),
      "payload_sha256" => sha256(payload)
    }

    atomic_write(path, Jason.encode!(artifact, pretty: true) <> "\n")
  end

  def load!(path) do
    %{
      "type" => "imp_test_multi_student_grpo_program",
      "schema_version" => 1,
      "payload" => encoded,
      "payload_sha256" => expected
    } = path |> File.read!() |> Jason.decode!()

    payload = Base.decode64!(encoded)

    unless :crypto.hash_equals(expected, sha256(payload)) do
      raise ArgumentError, "multi-student GRPO program checksum mismatch"
    end

    case :erlang.binary_to_term(payload) do
      %__MODULE__{} = program -> program
      _other -> raise ArgumentError, "invalid multi-student GRPO program payload"
    end
  end

  defp atomic_write(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, contents, [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

defmodule Imp.Test.FileMultiStudentGRPOTrainer do
  @moduledoc false
  @behaviour Imp.Clients.Trainer

  defstruct [:root, :runtime_mode]

  @impl true
  def supported_methods(_trainer), do: [:grpo]

  @impl true
  def start_reinforcement(trainer, lm, opts) do
    model = Map.fetch!(lm, :model)
    dispatch_id = Keyword.fetch!(opts, :dispatch_id)
    record(trainer, "start", model)

    session =
      Imp.Clients.ReinforcementSession.new(%{
        id: dispatch_id,
        provider: :file_multi_fixture,
        model: lm,
        pending_batch_ids: ["batch:#{model}"],
        backend_state: %{dispatch_id: dispatch_id}
      })

    save_session(trainer, session)
    {:ok, session}
  end

  @impl true
  def reconcile_reinforcement(trainer, dispatch_id) do
    record(trainer, "reconcile", dispatch_id)

    case load_session(trainer, dispatch_id) do
      %Imp.Clients.ReinforcementSession{id: ^dispatch_id} = session -> {:ok, session}
      _other -> {:error, :reinforcement_session_not_found}
    end
  end

  @impl true
  def reinforcement_status(_trainer, session), do: {:ok, session}

  @impl true
  def reinforcement_step(trainer, session, groups, _opts) do
    model = Map.fetch!(session.model, :model)
    record(trainer, "step", model)
    write_term(Path.join(student_root(trainer, model), "groups.term"), groups)

    artifact = Path.join(student_root(trainer, model), "artifact")
    ids = Enum.map(groups, & &1.batch_id)

    updated =
      session
      |> Imp.Clients.ReinforcementSession.fulfill(ids)
      |> Map.put(:current_model, artifact)
      |> Map.put(:result_model, artifact)
      |> Map.put(:metadata, %{
        artifact_sha256: digest("artifact:" <> model),
        checkpoint_sha256: digest("checkpoint:" <> model)
      })

    save_session(trainer, updated)

    if trainer.runtime_mode == {:hang_after_step, model}, do: Process.sleep(5_000)
    {:ok, updated}
  end

  @impl true
  def terminate_reinforcement(trainer, session) do
    model = Map.fetch!(session.model, :model)
    record(trainer, "terminate", model)
    updated = %{session | status: :succeeded, pending_batch_ids: []}
    save_session(trainer, updated)
    {:ok, updated}
  end

  @impl true
  def final_model_artifact(trainer, session) do
    model = Map.fetch!(session.model, :model)
    artifact = Path.join(student_root(trainer, model), "artifact")
    File.mkdir_p!(artifact)
    File.write!(Path.join(artifact, "identity"), model <> "\n", [:sync])
    {:ok, artifact}
  end

  def events(root) do
    case File.read(Path.join(root, "events")) do
      {:ok, value} -> String.split(value, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  def groups(root, model) do
    root
    |> student_root(model)
    |> Path.join("groups.term")
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  defp record(trainer, event, identity) do
    File.mkdir_p!(trainer.root)
    File.write!(Path.join(trainer.root, "events"), "#{event} #{identity}\n", [:append, :sync])
  end

  defp save_session(trainer, session) do
    path = session_path(trainer, session.id)
    write_term(path, session)
  end

  defp load_session(trainer, dispatch_id) do
    trainer
    |> session_path(dispatch_id)
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  rescue
    File.Error -> nil
  end

  defp session_path(trainer, dispatch_id) do
    Path.join([trainer.root, "sessions", digest(dispatch_id) <> ".term"])
  end

  defp student_root(root, model) when is_binary(root),
    do: Path.join([root, "students", digest(model)])

  defp student_root(trainer, model), do: student_root(trainer.root, model)

  defp write_term(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, :erlang.term_to_binary(value, [:deterministic]), [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp digest(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
