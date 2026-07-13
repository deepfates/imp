defmodule DSEx.Optimizer.SIMBA.Population do
  @moduledoc false

  alias DSEx.Optimizer.Sampling

  @baseline_id 0

  @enforce_keys [:programs, :program_ids, :score_histories, :next_id, :rng]
  defstruct [:programs, :program_ids, :score_histories, :next_id, :rng]

  @type program_id :: non_neg_integer()
  @type t :: %__MODULE__{
          programs: %{required(program_id()) => term()},
          program_ids: [program_id()],
          score_histories: %{required(program_id()) => [number()]},
          next_id: pos_integer(),
          rng: Sampling.state()
        }

  @spec baseline_id() :: 0
  def baseline_id, do: @baseline_id

  @spec new(term(), keyword()) :: t()
  def new(baseline, opts \\ []) do
    %__MODULE__{
      programs: %{@baseline_id => baseline},
      program_ids: [@baseline_id],
      score_histories: %{@baseline_id => []},
      next_id: 1,
      rng: Keyword.get_lazy(opts, :rng, fn -> Sampling.new(Keyword.get(opts, :seed, 0)) end)
    }
  end

  @doc """
  Registers a candidate unconditionally and stores its complete score history.

  Candidate quality is deliberately not checked: DSPy keeps worse candidates in
  the global pool so later sampling can continue to explore them.
  """
  @spec register(t(), term(), [number()]) :: t()
  def register(%__MODULE__{} = population, program, scores \\ []) do
    {_id, population} = register_with_id(population, program, scores)
    population
  end

  @spec register_with_id(t(), term(), [number()]) :: {program_id(), t()}
  def register_with_id(%__MODULE__{} = population, program, scores)
      when is_list(scores) do
    validate_scores!(scores)
    id = population.next_id

    {id,
     %{
       population
       | programs: Map.put(population.programs, id, program),
         program_ids: population.program_ids ++ [id],
         score_histories: Map.put(population.score_histories, id, scores),
         next_id: id + 1
     }}
  end

  @spec record_scores(t(), program_id(), [number()]) :: t()
  def record_scores(%__MODULE__{} = population, id, scores) when is_list(scores) do
    ensure_registered!(population, id)
    validate_scores!(scores)

    %{population | score_histories: Map.update!(population.score_histories, id, &(&1 ++ scores))}
  end

  @spec fetch_program!(t(), program_id()) :: term()
  def fetch_program!(%__MODULE__{} = population, id) do
    case Map.fetch(population.programs, id) do
      {:ok, program} -> program
      :error -> raise ArgumentError, "unknown SIMBA program id: #{inspect(id)}"
    end
  end

  @spec scores(t(), program_id()) :: [number()]
  def scores(%__MODULE__{} = population, id) do
    case Map.fetch(population.score_histories, id) do
      {:ok, scores} -> scores
      :error -> raise ArgumentError, "unknown SIMBA program id: #{inspect(id)}"
    end
  end

  @spec average_score(t(), program_id()) :: float()
  def average_score(%__MODULE__{} = population, id) do
    case scores(population, id) do
      [] -> 0.0
      scores -> Enum.sum(scores) / length(scores)
    end
  end

  @doc """
  Returns the top `k` IDs by average score while ensuring baseline ID `0` is present.
  """
  @spec top_k_plus_baseline(t(), non_neg_integer()) :: [program_id()]
  def top_k_plus_baseline(%__MODULE__{}, 0), do: []

  def top_k_plus_baseline(%__MODULE__{} = population, k)
      when is_integer(k) and k > 0 do
    top_k =
      population.program_ids
      |> Enum.sort_by(&average_score(population, &1), :desc)
      |> Enum.take(k)

    top_k =
      if @baseline_id in top_k do
        top_k
      else
        List.replace_at(top_k, -1, @baseline_id)
      end

    Enum.uniq(top_k)
  end

  @doc """
  Selects a source ID from the top candidates and returns the advanced population.

  `Sampling.softmax_choose/3` uses max-shifted exponentials, keeping the softmax
  stable for large score magnitudes.
  """
  @spec select_source(t(), pos_integer(), number()) :: {program_id(), t()}
  def select_source(%__MODULE__{} = population, k, temperature \\ 0.2)
      when is_integer(k) and k > 0 and is_number(temperature) and temperature > 0 do
    scored =
      population
      |> top_k_plus_baseline(k)
      |> Enum.map(&{&1, average_score(population, &1)})

    {id, rng} = Sampling.softmax_choose(scored, temperature, population.rng)
    {id, %{population | rng: rng}}
  end

  @spec select_source_program(t(), pos_integer(), number()) :: {term(), t()}
  def select_source_program(%__MODULE__{} = population, k, temperature \\ 0.2) do
    {id, population} = select_source(population, k, temperature)
    {fetch_program!(population, id), population}
  end

  defp ensure_registered!(population, id) do
    unless Map.has_key?(population.programs, id) do
      raise ArgumentError, "unknown SIMBA program id: #{inspect(id)}"
    end
  end

  defp validate_scores!(scores) do
    unless Enum.all?(scores, &is_number/1) do
      raise ArgumentError, "SIMBA score histories must contain only numbers"
    end
  end
end
