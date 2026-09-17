defmodule Imp.Optimizer.Utils do
  @moduledoc """
  Public optimizer utility surface, ported from DSPy's `dspy/teleprompt/utils.py`
  and `dspy/teleprompt/bootstrap_trace.py`.

  These are thin, upstream-named wrappers over Imp's existing internals
  (`Imp.Evaluate`, `Imp.Optimizer.DemoCandidates`,
  `Imp.Optimizer.TrajectoryRunner`); they add no logic of their own beyond
  the upstream calling conventions.
  """

  require Logger

  alias Imp.Optimizer.{DemoCandidates, Sampling, TrajectoryRunner}

  @doc """
  Evaluates a candidate program on the trainset, full or minibatched.

  Ports `eval_candidate_program` (dspy/teleprompt/utils.py): when
  `batch_size >= length(trainset)` the whole trainset is evaluated; otherwise
  a seeded random minibatch of `batch_size` examples is drawn (upstream's
  `create_minibatch`). The evaluator is an `%Imp.Evaluate{}` whose devset is
  replaced per call (upstream passes `devset=` to its evaluate callable).

  Faithful to upstream's failure contract: an exception during evaluation is
  logged and returns a zero-score result (upstream returns
  `Prediction(score=0.0, results=[])`; Imp returns an
  `%Imp.Evaluate.Result{score: 0.0}` with the error recorded in `:errors` —
  never discarded silently).

  Options: `:rng` (an `Imp.Optimizer.Sampling` state) or `:seed`
  (integer, default 0) for the minibatch draw.
  """
  @spec eval_candidate_program(
          pos_integer(),
          [Imp.Example.t()],
          struct(),
          Imp.Evaluate.t(),
          keyword()
        ) :: Imp.Evaluate.Result.t()
  def eval_candidate_program(batch_size, trainset, candidate_program, evaluator, opts \\ [])

  def eval_candidate_program(
        batch_size,
        trainset,
        candidate_program,
        %Imp.Evaluate{} = evaluator,
        opts
      )
      when is_integer(batch_size) and batch_size > 0 and is_list(trainset) do
    devset =
      if batch_size >= length(trainset) do
        trainset
      else
        {minibatch, _rng} = create_minibatch(trainset, batch_size, minibatch_rng(opts))
        minibatch
      end

    Imp.Evaluate.run(%{evaluator | devset: devset}, candidate_program)
  rescue
    error ->
      message = Exception.message(error)

      Logger.error(
        "Imp.Optimizer.Utils.eval_candidate_program: evaluation raised " <>
          "#{inspect(error.__struct__)}: #{message}; returning score 0.0 " <>
          "(upstream eval_candidate_program contract)"
      )

      %Imp.Evaluate.Result{
        score: 0.0,
        rows: [],
        errors: [%{stage: :eval_candidate_program, reason: message}]
      }
  end

  @doc """
  Draws a seeded random minibatch of `batch_size` examples without replacement.

  Ports `create_minibatch` (dspy/teleprompt/utils.py). `batch_size` is capped
  at the trainset length. Returns `{minibatch, rng}` so callers can thread
  the RNG state.
  """
  @spec create_minibatch([Imp.Example.t()], pos_integer(), Sampling.state()) ::
          {[Imp.Example.t()], Sampling.state()}
  def create_minibatch(trainset, batch_size, rng) when is_list(trainset) do
    {shuffled, rng} = Sampling.shuffle(trainset, rng)
    {Enum.take(shuffled, min(batch_size, length(trainset))), rng}
  end

  @doc """
  Builds `num_candidate_sets` few-shot demo sets per predictor.

  Ports `create_n_fewshot_demo_sets` (dspy/teleprompt/utils.py) as a thin
  wrapper over `Imp.Optimizer.DemoCandidates.build/4`, which implements the
  same seed schedule (zero-shot, labels-only, unshuffled bootstrap, shuffled
  bootstraps) and applies `:metric_threshold` uniformly to every round —
  including the unshuffled arm, which upstream skips.

  Returns a map of predictor name to a list of `num_candidate_sets` demo
  lists (upstream returns the same shape keyed by predictor index).
  Accepts `DemoCandidates.build/4` options (`:max_bootstrapped_demos`,
  `:max_labeled_demos`, `:metric_threshold`, `:teacher`, `:seed`, ...).
  """
  @spec create_n_fewshot_demo_sets(
          struct(),
          pos_integer(),
          [Imp.Example.t()],
          function(),
          keyword()
        ) :: %{optional(term()) => [[Imp.Example.t()]]}
  def create_n_fewshot_demo_sets(program, num_candidate_sets, trainset, metric, opts \\ [])
      when is_integer(num_candidate_sets) and num_candidate_sets > 0 do
    {by_predictor, _metadata} =
      DemoCandidates.build(
        program,
        trainset,
        metric,
        Keyword.put(opts, :candidate_count, num_candidate_sets)
      )

    by_predictor
  end

  @doc """
  Runs the program over the dataset and returns upstream-shaped trace rows.

  Ports the `bootstrap_trace_data` row contract
  (dspy/teleprompt/bootstrap_trace.py): one map per example with keys
  `:example`, `:prediction`, `:trace`, `:example_ind`, and `:score`, in
  dataset order. A failed example keeps its row with `prediction: nil`,
  `score: 0.0`, and the failure under `:error` (upstream substitutes a
  `FailedPrediction`; Imp retains equivalent structural format progress on the
  error trace so GRPO can shape partial multi-output formatting without
  accepting the invalid prediction).

  With `raise_on_error: true` (upstream's default) the first failure raises
  a `RuntimeError` instead.

  Other options are passed to `Imp.Optimizer.TrajectoryRunner.run/4`
  (`:max_concurrency`, `:timeout`, ...).
  """
  @spec bootstrap_trace_data(struct(), Enumerable.t(), function(), keyword()) :: [map()]
  def bootstrap_trace_data(program, dataset, metric, opts \\ []) do
    {raise_on_error, runner_opts} = Keyword.pop(opts, :raise_on_error, true)

    trajectories = TrajectoryRunner.run(program, dataset, metric, runner_opts)

    if raise_on_error do
      case Enum.find(trajectories, &(&1.error != nil)) do
        nil ->
          :ok

        trajectory ->
          raise RuntimeError,
                "bootstrap_trace_data failed on example #{trajectory.index}: " <>
                  inspect(trajectory.error)
      end
    end

    Enum.map(trajectories, fn trajectory ->
      %{
        example: trajectory.example,
        prediction: trajectory.prediction,
        trace: trajectory.trace,
        example_ind: trajectory.index,
        score: trajectory.score,
        error: trajectory.error
      }
    end)
  end

  defp minibatch_rng(opts) do
    case Keyword.fetch(opts, :rng) do
      {:ok, rng} -> rng
      :error -> Sampling.new(Keyword.get(opts, :seed, 0))
    end
  end
end
