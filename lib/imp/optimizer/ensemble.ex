defmodule Imp.Optimizer.Ensemble.Program do
  @moduledoc false
  @behaviour Imp.Module

  defstruct [:ensemble, programs: []]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    {programs, selection} =
      cond do
        program.ensemble.deterministic ->
          selected =
            Enum.take(program.programs, program.ensemble.size || length(program.programs))

          {selected, %{mode: :ordered, seed: program.ensemble.seed}}

        positive_size?(program.ensemble.size) ->
          rng = selection_rng(program.ensemble.seed, inputs)
          {shuffled, _rng} = Imp.Optimizer.Sampling.shuffle(program.programs, rng)

          {Enum.take(shuffled, program.ensemble.size),
           %{mode: :seeded, seed: program.ensemble.seed}}

        true ->
          {program.programs, %{mode: :all, seed: program.ensemble.seed}}
      end

    outputs = Enum.map(programs, &safe_call(&1, inputs))

    if program.ensemble.reduce_fn do
      predictions =
        Enum.flat_map(outputs, fn
          {:ok, pred} -> [pred]
          _ -> []
        end)

      reduce(program.ensemble.reduce_fn, predictions, outputs)
    else
      {:ok, Imp.Prediction.new(%{outputs: outputs}, metadata: %{ensemble_selection: selection})}
    end
  end

  # DSPy selects a subset only when `size` is truthy. In that public contract,
  # both `None` and `0` mean "use every program". Elixir treats zero as truthy,
  # so an explicit numeric predicate is required to preserve the behavior.
  defp positive_size?(size), do: is_integer(size) and size > 0

  defp selection_rng(seed, inputs) do
    derived_seed =
      {seed, inputs}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 8)
      |> :binary.decode_unsigned()

    Imp.Optimizer.Sampling.new(derived_seed)
  end

  defp safe_call(program, inputs) do
    case Imp.Module.call(program, inputs) do
      {:ok, %Imp.Prediction{} = prediction} ->
        {:ok, prediction}

      {:ok, other} ->
        {:error, {:invalid_ensemble_prediction, inspect(other)}}

      {:error, {:module_call_failed, _module, reason}} ->
        {:error, {:ensemble_program_failed, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_ensemble_result, inspect(other)}}
    end
  rescue
    error -> {:error, {:ensemble_program_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:ensemble_program_failed, error_message({kind, reason})}}
  end

  defp reduce(reduce_fn, predictions, outputs) do
    case reduce_fn.(predictions) do
      %Imp.Prediction{} = prediction ->
        {:ok, prediction}

      %{} = fields ->
        {:ok, Imp.Prediction.new(fields)}

      other ->
        {:error, {:invalid_ensemble_reduction, inspect(other), outputs}}
    end
  rescue
    error -> {:error, {:ensemble_reduce_failed, error_message(error), outputs}}
  catch
    kind, reason -> {:error, {:ensemble_reduce_failed, error_message({kind, reason}), outputs}}
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

defmodule Imp.Optimizer.Ensemble do
  @behaviour Imp.Optimizer
  @moduledoc """
  Compile multiple programs into an ensemble program.

  Each child program is called independently. `size: nil` and `size: 0` both
  execute every child, matching DSPy's public subset-selection behavior. A
  positive `:size` selects that many children. A failed child contributes an
  `{:error, reason}` entry to the ensemble outputs instead of crashing the whole
  ensemble. When a `:reduce_fn` is supplied, it receives only successful
  predictions; reducer exceptions or invalid reducer returns become structured
  `{:error, reason}` results. When `:size` selects a random subset, `:seed`
  drives a pure per-input RNG stream, so the same saved ensemble and inputs
  replay the same selection without depending on process-global random state.
  """

  defstruct reduce_fn: nil, size: nil, deterministic: false, seed: 0

  @option_schema [
    reduce_fn: [
      type: {:custom, __MODULE__, :validate_reduce_fn, []},
      default: nil
    ],
    size: [type: {:or, [:non_neg_integer, nil]}, default: nil],
    deterministic: [type: :boolean, default: false],
    seed: [type: :integer, default: 0]
  ]

  def new(opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.Ensemble.new/1")

    %__MODULE__{
      reduce_fn: opts[:reduce_fn],
      size: opts[:size],
      deterministic: opts[:deterministic],
      seed: opts[:seed]
    }
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :constructor,
      datasets: %{trainset: :unsupported, validation: :unsupported},
      result: :constructed_program
    }

  @impl true
  def run(%__MODULE__{} = ensemble, programs, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok, compile(ensemble, programs)}
    end
  end

  def compile(%__MODULE__{} = ensemble, programs) do
    programs = validate_programs!(programs)
    validate_size!(ensemble.size, programs)

    %Imp.Optimizer.Ensemble.Program{
      programs: programs,
      ensemble: ensemble
    }
  end

  defp validate_programs!(programs) do
    if Enumerable.impl_for(programs) do
      Enum.to_list(programs)
    else
      raise ArgumentError,
            "Imp.Optimizer.Ensemble.compile/2 expects an enumerable of programs; got: #{inspect(programs)}"
    end
  end

  defp validate_size!(size, programs)
       when is_integer(size) and size > length(programs) do
    raise ArgumentError,
          "Imp.Optimizer.Ensemble.compile/2 cannot sample :size #{size} from #{length(programs)} programs"
  end

  defp validate_size!(_size, _programs), do: :ok

  def validate_reduce_fn(nil), do: {:ok, nil}
  def validate_reduce_fn(reduce_fn) when is_function(reduce_fn, 1), do: {:ok, reduce_fn}

  def validate_reduce_fn(reduce_fn) do
    {:error, "expected nil or an arity-1 function, got: #{inspect(reduce_fn)}"}
  end
end
