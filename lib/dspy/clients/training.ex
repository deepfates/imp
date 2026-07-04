defmodule DSPy.Clients.TrainingJob do
  @moduledoc "Provider-neutral finetuning or reinforcement-training job."

  defstruct [:id, :provider, :model, :status, :training_data, :result_model, metadata: %{}]

  def new(attrs) do
    %__MODULE__{
      id:
        Map.get(attrs, :id) ||
          "train-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      provider: Map.get(attrs, :provider, :local),
      model: Map.get(attrs, :model),
      status: Map.get(attrs, :status, :created),
      training_data: Map.get(attrs, :training_data, []),
      result_model: Map.get(attrs, :result_model),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  def complete(%__MODULE__{} = job, result_model),
    do: %{job | status: :succeeded, result_model: result_model}

  def fail(%__MODULE__{} = job, reason),
    do: %{job | status: :failed, metadata: Map.put(job.metadata, :error, reason)}
end

defmodule DSPy.Clients.Trainer do
  @moduledoc "Behaviour for provider-specific training backends."

  @callback finetune(DSPy.Clients.HTTPLM.t() | term(), list(DSPy.Example.t()), keyword()) ::
              {:ok, DSPy.Clients.TrainingJob.t()} | {:error, term()}

  def finetune(provider, lm, examples, opts \\ [])

  def finetune(module, lm, examples, opts) when is_atom(module),
    do: module.finetune(lm, examples, opts)

  def finetune(fun, lm, examples, opts) when is_function(fun, 3), do: fun.(lm, examples, opts)
end

defmodule DSPy.Clients.LocalTrainer do
  @moduledoc "Deterministic local trainer that records data and returns a completed job."

  @behaviour DSPy.Clients.Trainer

  @impl true
  def finetune(lm, examples, opts) do
    suffix = Keyword.get(opts, :suffix, "finetuned")
    model = Map.get(lm, :model, "local-model")

    {:ok,
     DSPy.Clients.TrainingJob.new(%{
       provider: :local,
       model: model,
       status: :succeeded,
       training_data: Enum.map(examples, &DSPy.Example.to_map/1),
       result_model: "#{model}:#{suffix}"
     })}
  end
end
