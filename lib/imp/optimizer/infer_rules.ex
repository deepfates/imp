defmodule Imp.Optimizer.InferRules do
  @behaviour Imp.Optimizer
  @moduledoc """
  Induces natural-language rules from observed examples and selects them on a
  validation set.

  This follows DSPy 3.2.1 `InferRules`' semantic loop: it first runs
  `BootstrapFewShot`, formats each predictor's observed input/output examples,
  asks a fresh rule-induction program for actionable rules, appends those rules
  to the predictor's instructions, and evaluates each candidate. Imp retains
  the bootstrapped baseline as an additional safety candidate so rule induction
  cannot silently regress the supplied program.

  Candidate programs and signatures remain immutable and isolated, so a later
  proposal cannot rewrite an already selected candidate through shared Python
  signature-class state. Proposal and evaluation failures are retained in the
  optimizer report instead of aborting the whole compile. Unlike upstream,
  context-window failures are not yet retried with progressively fewer examples.
  Those are deliberate native control-flow differences, not claims of exact
  whole-loop equivalence.

  Pass `:rule_lm` (or `:prompt_lm`) to keep rule induction separate from the
  task LM. Without one, the program's bound LM is used. `:candidates` accepts
  already-induced rule strings and is useful for deterministic replay.
  """

  defstruct [
    :metric,
    :rule_lm,
    :bootstrap,
    candidates: [],
    num_candidates: 10,
    num_rules: 10,
    num_threads: nil
  ]

  @option_schema [
    candidates: [type: {:list, :string}, default: []],
    num_candidates: [type: :pos_integer, default: 10],
    num_rules: [type: :pos_integer, default: 10],
    num_threads: [type: {:or, [:pos_integer, nil]}, default: nil],
    rule_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    prompt_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    metric_threshold: [
      type: {:custom, Imp.Optimizer.BootstrapFewShot, :validate_optional_number, []},
      default: nil
    ],
    teacher_settings: [type: :keyword_list, default: []],
    max_bootstrapped_demos: [type: :non_neg_integer, default: 4],
    max_labeled_demos: [type: :non_neg_integer, default: 16],
    max_rounds: [type: :non_neg_integer, default: 1],
    max_errors: [
      type: {:custom, Imp.Optimizer.BootstrapFewShot, :validate_optional_max_errors, []},
      default: nil
    ],
    timeout: [type: {:or, [:timeout, :pos_integer]}, default: 5_000]
  ]

  @bootstrap_keys [
    :metric_threshold,
    :teacher_settings,
    :max_bootstrapped_demos,
    :max_labeled_demos,
    :max_rounds,
    :max_errors,
    :timeout
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(
      metric,
      [2, 3],
      "Imp.Optimizer.InferRules.new/2",
      "metric"
    )

    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.InferRules.new/2")
    rule_lm = opts[:rule_lm] || opts[:prompt_lm]
    bootstrap_opts = Keyword.take(opts, @bootstrap_keys)

    %__MODULE__{
      metric: metric,
      rule_lm: rule_lm,
      bootstrap: Imp.Optimizer.BootstrapFewShot.new(metric, bootstrap_opts),
      candidates: opts[:candidates],
      num_candidates: opts[:num_candidates],
      num_rules: opts[:num_rules],
      num_threads: opts[:num_threads]
    }
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :optional},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    invocation = Imp.Optimizer.invocation_options(opts)
    {teacher, invocation} = Keyword.pop(invocation, :teacher)

    with :ok <- Imp.Optimizer.reject_options(invocation) do
      {:ok,
       compile(
         optimizer,
         program,
         Imp.Optimizer.fetch_dataset!(opts, :trainset),
         Keyword.get(opts, :validation),
         teacher: teacher
       )}
    end
  end

  def compile(%__MODULE__{} = optimizer, program, trainset),
    do: compile(optimizer, program, trainset, nil, [])

  def compile(%__MODULE__{} = optimizer, program, trainset, devset),
    do: compile(optimizer, program, trainset, devset, [])

  def compile(%__MODULE__{} = optimizer, program, trainset, devset, opts)
      when is_list(opts) do
    {trainset, devset} = datasets(trainset, devset)
    ensure_predictors!(program)

    baseline =
      Imp.Optimizer.BootstrapFewShot.compile(
        optimizer.bootstrap,
        program,
        trainset,
        teacher: Keyword.get(opts, :teacher)
      )

    bootstrap_report = Imp.Optimizer.Report.fetch(baseline)
    rule_lm = resolve_rule_lm(optimizer, baseline)

    {candidates, proposal_errors, proposal_calls} =
      build_candidates(optimizer, baseline, trainset, rule_lm)

    evaluation_max_errors = bootstrap_report.metadata.max_errors
    evaluator = evaluator(devset, optimizer, evaluation_max_errors)

    evaluated =
      [%{program: baseline, index: :baseline, rules: %{}, baseline: true} | candidates]
      |> Enum.map(&evaluate_candidate(evaluator, &1))

    {best, best_score} = select_best(evaluated, baseline)

    evaluation_errors =
      Enum.flat_map(evaluated, fn
        %{status: :error} = row ->
          [Map.drop(row, [:program])]

        %{status: :with_errors, errors: errors} = row ->
          [%{stage: :evaluation, candidate: row.index, errors: errors}]

        _row ->
          []
      end)

    report_candidates =
      Enum.map(evaluated, fn row ->
        Map.take(row, [:index, :rules, :baseline, :score, :status, :error, :errors])
      end)

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :infer_rules,
        best_score: best_score,
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: proposal_errors ++ evaluation_errors,
        metadata: %{
          implementation: :native_rule_induction,
          upstream: "DSPy 3.2.1 InferRules",
          baseline_protected: true,
          bootstrap: report_summary(bootstrap_report),
          explicit_candidates: optimizer.candidates != [],
          num_candidates: candidate_count(optimizer),
          num_rules: optimizer.num_rules,
          proposal_calls: proposal_calls,
          evaluation_max_errors: evaluation_max_errors,
          predictor_names: Enum.map(Imp.ProgramParameters.predictors(baseline), & &1.name),
          trainset_size: length(trainset),
          validation_size: length(devset),
          status:
            if(proposal_errors == [] and evaluation_errors == [], do: :ok, else: :with_errors)
        }
      })

    Imp.Optimizer.Report.attach(best, report)
  end

  defp format_examples(examples, %Imp.Signature{} = signature) do
    input_names = Imp.Signature.input_names(signature)
    output_names = Imp.Signature.output_names(signature)

    examples
    |> Enum.map(fn example ->
      fields = example_fields(example)
      inputs = format_named_fields(fields, input_names)
      outputs = format_named_fields(fields, output_names)

      "Input Fields:\n#{inputs}\n\n=========\nOutput Fields:\n#{outputs}\n\n"
    end)
    |> Enum.join()
  end

  defp build_candidates(%{candidates: candidates}, baseline, _trainset, _rule_lm)
       when candidates != [] do
    rows =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {rules, index} ->
        rules_by_predictor =
          Map.new(Imp.ProgramParameters.predictors(baseline), &{&1.name, rules})

        %{
          program: apply_rules(baseline, rules_by_predictor),
          index: index,
          rules: rules_by_predictor,
          baseline: false
        }
      end)

    {rows, [], 0}
  end

  defp build_candidates(_optimizer, _baseline, _trainset, nil) do
    error = %{
      stage: :rule_induction,
      error: "no rule LM is configured or bound to the program"
    }

    {[], [error], 0}
  end

  defp build_candidates(optimizer, baseline, trainset, rule_lm) do
    predictors = Imp.ProgramParameters.predictors(baseline)

    0..(optimizer.num_candidates - 1)
    |> Enum.reduce({[], [], 0}, fn candidate_index, {rows, errors, calls} ->
      result =
        predictors
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, %{}, calls}, fn {%{name: name, predictor: predictor},
                                                    predictor_index},
                                                   {:ok, rules, calls} ->
          examples_text = format_examples(trainset, predictor.signature)
          rollout_id = candidate_index * max(length(predictors), 1) + predictor_index

          case induce_rules(
                 rule_lm,
                 examples_text,
                 optimizer.num_rules,
                 rollout_id,
                 optimizer.bootstrap.teacher_settings
               ) do
            {:ok, induced} -> {:cont, {:ok, Map.put(rules, name, induced), calls + 1}}
            {:error, reason} -> {:halt, {:error, name, reason, calls + 1}}
          end
        end)

      case result do
        {:ok, rules, calls} ->
          row = %{
            program: apply_rules(baseline, rules),
            index: candidate_index,
            rules: rules,
            baseline: false
          }

          {rows ++ [row], errors, calls}

        {:error, predictor, reason, calls} ->
          error = %{
            stage: :rule_induction,
            candidate: candidate_index,
            predictor: predictor,
            error: error_message(reason)
          }

          {rows, errors ++ [error], calls}
      end
    end)
  end

  defp induce_rules(rule_lm, examples_text, num_rules, rollout_id, teacher_settings) do
    signature =
      Imp.signature(
        "examples_text -> natural_language_rules",
        "Given the examples, extract #{num_rules} concise, non-redundant natural-language rules. Each rule must be actionable for a well-specified scope of similar examples."
      )

    program =
      Imp.Predict.ChainOfThought.new(signature,
        lm: rule_lm,
        config: [temperature: 1.0, rollout_id: rollout_id]
      )

    Imp.Settings.context(teacher_settings, fn ->
      with {:ok, prediction} <-
             Imp.Predict.ChainOfThought.call(program, %{examples_text: examples_text}),
           {:ok, rules} <- normalize_rules(Imp.get(prediction, :natural_language_rules)) do
        {:ok, rules}
      end
    end)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_rules(rules) when is_binary(rules) do
    case String.trim(rules) do
      "" -> {:error, :empty_natural_language_rules}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_rules(rules) when is_list(rules),
    do: rules |> Enum.map(&to_string/1) |> Enum.join("\n") |> normalize_rules()

  defp normalize_rules(rules), do: {:error, {:invalid_natural_language_rules, rules}}

  defp apply_rules(program, rules_by_predictor) do
    Enum.reduce(rules_by_predictor, program, fn {name, rules}, current ->
      %{predictor: predictor} =
        Enum.find(Imp.ProgramParameters.predictors(current), &(&1.name == name))

      base = predictor.signature.instructions

      instructions =
        "#{base}\n\nPlease adhere to the following rules when making your prediction:\n#{rules}"

      Imp.ProgramParameters.put_instruction(current, name, instructions)
    end)
  end

  defp evaluator(devset, optimizer, max_errors) do
    opts = [max_errors: max_errors]

    opts =
      if optimizer.num_threads,
        do: Keyword.put(opts, :max_concurrency, optimizer.num_threads),
        else: opts

    Imp.Evaluate.new(devset, optimizer.metric, opts)
  end

  defp evaluate_candidate(evaluator, candidate) do
    result = Imp.Evaluate.run(evaluator, candidate.program)

    if result.errors == [] do
      Map.merge(candidate, %{score: result.score, status: :ok})
    else
      Map.merge(candidate, %{score: result.score, status: :with_errors, errors: result.errors})
    end
  rescue
    error -> Map.merge(candidate, %{score: nil, status: :error, error: error_message(error)})
  catch
    kind, reason ->
      Map.merge(candidate, %{score: nil, status: :error, error: error_message({kind, reason})})
  end

  defp select_best(evaluated, fallback) do
    case Enum.filter(evaluated, &(&1.status in [:ok, :with_errors] and is_number(&1.score))) do
      [] ->
        {fallback, nil}

      successful ->
        best = Enum.max_by(successful, & &1.score)
        {best.program, best.score}
    end
  end

  defp datasets(trainset, nil) do
    rows = Enum.to_list(trainset)
    Enum.split(rows, trunc(0.5 * length(rows)))
  end

  defp datasets(trainset, devset), do: {Enum.to_list(trainset), Enum.to_list(devset)}

  defp resolve_rule_lm(optimizer, program) do
    optimizer.rule_lm ||
      Keyword.get(optimizer.bootstrap.teacher_settings, :lm) ||
      Imp.ProgramAccess.lm(program) ||
      Imp.Settings.get().lm
  end

  defp candidate_count(%{candidates: candidates}) when candidates != [], do: length(candidates)
  defp candidate_count(optimizer), do: optimizer.num_candidates

  defp report_summary(nil), do: nil

  defp report_summary(report) do
    %{
      optimizer: report.optimizer,
      best_score: report.best_score,
      candidate_count: report.candidate_count,
      error_count: length(report.errors)
    }
  end

  defp ensure_predictors!(program) do
    case Imp.ProgramParameters.predictors(program) do
      [] ->
        raise ArgumentError,
              "InferRules requires a program that exposes at least one optimizer predictor"

      _predictors ->
        :ok
    end
  end

  defp example_fields(%Imp.Example{} = example), do: Imp.Example.to_map(example)
  defp example_fields(example) when is_map(example), do: example

  defp example_fields(example),
    do: raise(ArgumentError, "invalid InferRules example: #{inspect(example)}")

  defp format_named_fields(fields, names) do
    names
    |> Enum.flat_map(fn name ->
      case fetch_field(fields, name) do
        {:ok, value} -> ["#{name}: #{format_value(value)}"]
        :error -> []
      end
    end)
    |> Enum.join("\n")
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp fetch_field(fields, name) do
    case Map.fetch(fields, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(fields, to_string(name))
    end
  end

  defp error_message(%_{} = error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)
end
