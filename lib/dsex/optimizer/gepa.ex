defmodule DSEx.Optimizer.GEPA do
  @moduledoc "Reflective prompt optimizer that turns feedback into instruction candidates."

  defstruct [:metric, feedback_fn: nil, generations: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      feedback_fn: Keyword.get(opts, :feedback_fn),
      generations: Keyword.get(opts, :generations, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    feedback =
      case optimizer.feedback_fn do
        nil -> default_feedback(trainset)
        fun when is_function(fun, 1) -> fun.(trainset)
      end

    base = DSEx.Optimizer.InstructionSearch.candidate_instructions(program, trainset)

    candidates =
      (base ++
         Enum.map(1..optimizer.generations, fn index ->
           "#{feedback}\nReflection #{index}: repair likely mistakes before answering."
         end))
      |> Enum.take(length(base) + optimizer.generations)

    compiled =
      DSEx.Optimizer.InstructionSearch.compile(
        program,
        optimizer.metric,
        trainset,
        devset,
        candidates
      )

    search_report = DSEx.Optimizer.Report.fetch(compiled)

    DSEx.Optimizer.Report.attach(
      compiled,
      DSEx.Optimizer.Report.new(%{
        optimizer: :gepa,
        best_score: search_report.best_score,
        candidate_count: search_report.candidate_count,
        candidates: search_report.candidates,
        metadata: %{
          feedback: feedback,
          generations: optimizer.generations,
          base_candidate_count: length(base)
        }
      })
    )
  end

  defp default_feedback(trainset),
    do: "Use observed examples carefully. Training examples available: #{length(trainset)}."
end
