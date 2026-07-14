defmodule Imp.Optimizer.BootstrapFinetune do
  @behaviour Imp.Optimizer
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  alias Imp.Clients.TrainingJob
  alias Imp.Optimizer.TrainingResult

  defstruct [:metric, :trainer, max_demos: 32]

  @option_schema [
    trainer: [type: {:custom, Imp.Clients.Trainer, :validate_provider, []}, default: nil],
    max_demos: [type: :non_neg_integer, default: 32]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(
      metric,
      [2, 3],
      "Imp.Optimizer.BootstrapFinetune.new/2",
      "metric"
    )

    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.BootstrapFinetune.new/2")

    %__MODULE__{
      metric: metric,
      trainer: opts[:trainer],
      max_demos: opts[:max_demos]
    }
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :training,
      datasets: %{trainset: :required, validation: :unsupported},
      result: :training_result
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      case compile(optimizer, program, Imp.Optimizer.fetch_dataset!(opts, :trainset)) do
        %{program: compiled, job: %TrainingJob{} = job} ->
          training_result(compiled, job)

        %{program: _compiled, job: job} ->
          {:error, {:invalid_training_job, job}}

        %{program: compiled, error: reason} ->
          {:error, {:training_not_started, reason, compiled}}
      end
    end
  end

  defp training_result(compiled, %TrainingJob{status: :succeeded} = job) do
    case TrainingJob.rebind(job, compiled) do
      {:ok, rebound} ->
        {:ok,
         %TrainingResult{
           program: rebound,
           job: job,
           status: :completed,
           metadata: %{method: :sft}
         }}

      {:error, reason} ->
        {:error, {:training_rebind_failed, reason}}
    end
  end

  defp training_result(compiled, %TrainingJob{status: status} = job)
       when status in [:created, :pending, :running] do
    {:ok,
     %TrainingResult{
       program: compiled,
       job: job,
       status: :job_created,
       metadata: %{method: :sft}
     }}
  end

  defp training_result(_compiled, %TrainingJob{status: status} = job),
    do: {:error, {:training_failed, status, job.metadata}}

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    boot =
      Imp.Optimizer.BootstrapFewShot.new(optimizer.metric,
        max_bootstrapped_demos: optimizer.max_demos
      )

    compiled = Imp.Optimizer.BootstrapFewShot.compile(boot, program, trainset)
    demos = Imp.ProgramAccess.demos(compiled)
    lm = Imp.ProgramAccess.lm(compiled)

    case optimizer.trainer do
      nil ->
        %{program: compiled, error: :trainer_required}

      trainer ->
        with {:ok, trainer_opts} <- trainer_opts(trainer, compiled),
             {:ok, job} <-
               Imp.Clients.Trainer.finetune(trainer, lm || %{}, demos, trainer_opts) do
          %{program: compiled, job: job}
        else
          {:error, reason} -> %{program: compiled, error: reason}
        end
    end
  end

  defp trainer_opts(%Imp.Clients.HTTPTrainer{provider: :openai}, compiled) do
    with {:ok, encoder} <- openai_example_encoder(compiled) do
      {:ok, [method: :sft, example_encoder: encoder]}
    end
  end

  defp trainer_opts(_trainer, _compiled), do: {:ok, [method: :sft]}

  defp openai_example_encoder(compiled) do
    case Imp.ProgramAccess.predict(compiled) do
      %Imp.Predict.Predict{signature: %Imp.Signature{} = signature} = predict ->
        adapter = resolve_adapter(predict)
        {:ok, fn example -> render_openai_row(adapter, signature, example) end}

      _program ->
        {:error, :openai_training_representation_unavailable}
    end
  end

  defp resolve_adapter(%Imp.Predict.Predict{dynamic_adapter?: true}),
    do: Imp.Settings.get().adapter

  defp resolve_adapter(%Imp.Predict.Predict{adapter: nil}), do: Imp.Settings.get().adapter
  defp resolve_adapter(%Imp.Predict.Predict{adapter: adapter}), do: adapter

  defp render_openai_row(adapter, signature, example) do
    messages = adapter.format(signature, %{}, demos: [example], response_instruction: false)

    {systems, turn} = Enum.split_while(messages, &(message_role(&1) == :system))

    case turn do
      [user, assistant | _rest] ->
        if systems != [] and message_role(user) == :user and
             message_role(assistant) == :assistant do
          {:ok, %{messages: systems ++ [user, assistant]}}
        else
          {:error, :openai_chat_messages_unavailable}
        end

      _messages ->
        {:error, :openai_chat_messages_unavailable}
    end
  rescue
    error -> {:error, {:openai_chat_render_failed, Exception.message(error)}}
  end

  defp message_role(%{role: "system"}), do: :system
  defp message_role(%{role: "user"}), do: :user
  defp message_role(%{role: "assistant"}), do: :assistant
  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => "system"}), do: :system
  defp message_role(%{"role" => "user"}), do: :user
  defp message_role(%{"role" => "assistant"}), do: :assistant
  defp message_role(_message), do: nil
end
