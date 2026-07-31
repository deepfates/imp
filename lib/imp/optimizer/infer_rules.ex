defmodule Imp.Optimizer.InferRules do
  @behaviour Imp.Optimizer
  @moduledoc """
  Induces natural-language rules from observed examples and selects them on a
  validation set.

  This follows DSPy 3.2.1 `InferRules`' semantic loop: it first runs
  `BootstrapFewShot`, formats each predictor's observed input/output examples,
  asks a fresh rule-induction program for actionable rules, appends those rules
  to the predictor's instructions, and evaluates each candidate. Imp retains
  both the supplied source program and the bootstrapped baseline as safety
  candidates. The source is evaluated first, so neither bootstrapping nor rule
  induction can silently regress it on the selection set.

  Candidate programs and signatures remain immutable and isolated, so a later
  proposal cannot rewrite an already selected candidate through shared Python
  signature-class state. Context-window failures retry with progressively fewer
  examples, matching upstream's user-visible recovery policy. Proposal and
  evaluation failures, including exhausted context retries, are retained in the
  optimizer report instead of aborting the whole compile. Those are deliberate
  native control-flow differences, not claims of exact whole-loop equivalence.
  Imp also reuses a logical call's sequential rollout ID while its prompt
  shrinks; DSPy draws a fresh random rollout ID for every retry.

  Operational route, cost, budget, transport, and cancellation guards are
  never candidate-local: they remain fatal through both rule induction and
  candidate evaluation.

  Pass `:rule_lm` (or `:prompt_lm`) to keep rule induction separate from the
  task LM. Without one, the program's bound LM is used. `:candidates` accepts
  already-induced rule strings and is useful for deterministic replay.

  Durable runs accept `:max_operations`, `:checkpoint_fn`, and `:resume_state`
  at compile time. Operations seal the bootstrap, each predictor's rule
  proposal, and each whole candidate evaluation. Anonymous or captured metrics
  require a stable JSON-safe `:metric_identity`; complete in-process runs remain
  available without one and explicitly produce no resume state.
  """

  alias Imp.Optimizer.{DurableCallbackIdentity, Report}
  alias Imp.Optimizer.InferRules.Checkpoint

  defstruct [
    :metric,
    :metric_identity,
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
    metric_identity: [type: :any, default: nil],
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

  @compile_option_schema [
    teacher: [type: :any, default: nil],
    resume_state: [
      type: {:custom, Imp.Optimize.Anything, :validate_resume_state, []},
      default: nil
    ],
    checkpoint_fn: [
      type: {:custom, Imp.Optimize.Anything, :validate_checkpoint_fn, []},
      default: nil
    ],
    max_operations: [type: {:or, [:non_neg_integer, {:in, [:infinity]}]}, default: :infinity]
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
      metric_identity:
        DurableCallbackIdentity.normalize!(opts[:metric_identity], :metric_identity),
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
    invocation =
      opts
      |> Imp.Optimizer.invocation_options()
      |> validate_compile_options!()

    {:ok,
     compile(
       optimizer,
       program,
       Imp.Optimizer.fetch_dataset!(opts, :trainset),
       Keyword.get(opts, :validation),
       invocation
     )}
  end

  @impl true
  def validate_invocation_options(opts) do
    _validated = validate_compile_options!(opts)
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def compile(%__MODULE__{} = optimizer, program, trainset),
    do: compile(optimizer, program, trainset, nil, [])

  def compile(%__MODULE__{} = optimizer, program, trainset, devset),
    do: compile(optimizer, program, trainset, devset, [])

  def compile(%__MODULE__{} = optimizer, program, trainset, devset, opts)
      when is_list(opts) do
    opts = validate_compile_options!(opts)
    {trainset, devset} = datasets(trainset, devset)
    ensure_predictors!(program)
    :ok = DurableCallbackIdentity.validate_normalized!(optimizer.metric_identity, "InferRules")

    durable? =
      DurableCallbackIdentity.durable?(
        optimizer.metric,
        optimizer.metric_identity,
        durable_controls?(opts)
      )

    metric_identity =
      DurableCallbackIdentity.resolve!(
        optimizer.metric,
        optimizer.metric_identity,
        durable?,
        "InferRules",
        :metric_identity
      )

    compatibility =
      resume_compatibility(program, trainset, devset, optimizer, opts, metric_identity)

    {state, resumed?} =
      case opts[:resume_state] do
        nil ->
          state = initial_state()
          emit_checkpoint(opts[:checkpoint_fn], durable?, compatibility, state)
          {state, false}

        checkpoint ->
          {Checkpoint.load!(checkpoint, compatibility, program), true}
      end

    operation_limit =
      invocation_operation_limit(state.completed_operations, opts[:max_operations])

    state =
      run_until_boundary(
        state,
        optimizer,
        program,
        trainset,
        devset,
        opts,
        operation_limit,
        durable?,
        compatibility
      )

    complete? = run_complete?(state)
    fallback = state.baseline || program
    {best, best_score} = select_best(state.evaluated, fallback)

    evaluation_errors =
      Enum.flat_map(state.evaluated, fn
        %{status: :error} = row ->
          [Map.drop(row, [:program])]

        %{status: :with_errors, errors: errors} = row ->
          [%{stage: :evaluation, candidate: row.index, errors: errors}]

        _row ->
          []
      end)

    report_candidates =
      Enum.map(state.evaluated, fn row ->
        Map.take(row, [:index, :rules, :source, :baseline, :score, :status, :error, :errors])
      end)

    checkpoint = if durable?, do: Checkpoint.dump(compatibility, state)

    report =
      Report.new(%{
        optimizer: :infer_rules,
        best_score: best_score,
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: state.proposal_errors ++ evaluation_errors,
        metadata: %{
          implementation: :native_rule_induction,
          upstream: "DSPy 3.2.1 InferRules",
          source_protected: true,
          baseline_protected: true,
          bootstrap: state.bootstrap_summary,
          explicit_candidates: optimizer.candidates != [],
          num_candidates: candidate_count(optimizer),
          num_rules: optimizer.num_rules,
          proposal_calls: state.proposal_calls,
          proposal_attempts: state.proposal_attempts,
          evaluation_max_errors: state.evaluation_max_errors,
          predictor_names: Enum.map(Imp.ProgramParameters.predictors(fallback), & &1.name),
          trainset_size: length(trainset),
          validation_size: length(devset),
          durable: durable?,
          metric_identity: metric_identity,
          resumed: resumed?,
          completed_operations: state.completed_operations,
          run_status: if(complete?, do: :complete, else: :paused),
          resume_state: checkpoint,
          status:
            if(state.proposal_errors == [] and evaluation_errors == [],
              do: :ok,
              else: :with_errors
            )
        }
      })

    attach_report(best, report)
  end

  def compile(%__MODULE__{}, _program, _trainset, _devset, opts) do
    raise ArgumentError,
          "Imp.Optimizer.InferRules.compile/5 expects keyword options, got: #{inspect(opts)}"
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

  defp validate_compile_options!(opts) do
    Imp.Options.validate!(
      opts,
      @compile_option_schema,
      "Imp.Optimizer.InferRules.compile/5"
    )
  end

  defp initial_state do
    %{
      baseline: nil,
      bootstrap_summary: nil,
      evaluation_max_errors: nil,
      proposals_complete: false,
      next_candidate_index: 0,
      proposal_cursor: nil,
      candidates: [],
      proposal_errors: [],
      proposal_calls: 0,
      proposal_attempts: 0,
      evaluated: [],
      completed_operations: 0
    }
  end

  defp run_until_boundary(
         state,
         optimizer,
         program,
         trainset,
         devset,
         opts,
         operation_limit,
         durable?,
         compatibility
       ) do
    cond do
      run_complete?(state) ->
        state

      operation_budget_exhausted?(state.completed_operations, operation_limit) ->
        state

      true ->
        state = advance_once(state, optimizer, program, trainset, devset, opts)
        emit_checkpoint(opts[:checkpoint_fn], durable?, compatibility, state)

        run_until_boundary(
          state,
          optimizer,
          program,
          trainset,
          devset,
          opts,
          operation_limit,
          durable?,
          compatibility
        )
    end
  end

  defp advance_once(%{baseline: nil} = state, optimizer, program, trainset, _devset, opts) do
    baseline =
      Imp.Optimizer.BootstrapFewShot.compile(
        optimizer.bootstrap,
        program,
        trainset,
        teacher: opts[:teacher]
      )

    report = fetch_report!(baseline, :bootstrap_few_shot)

    %{
      state
      | baseline: baseline,
        bootstrap_summary: report_summary(report),
        evaluation_max_errors: report.metadata.max_errors,
        completed_operations: state.completed_operations + 1
    }
  end

  defp advance_once(
         %{proposals_complete: false} = state,
         optimizer,
         _program,
         trainset,
         _devset,
         _opts
       ) do
    advance_proposal(state, optimizer, trainset)
  end

  defp advance_once(state, optimizer, program, _trainset, devset, _opts) do
    plan = evaluation_plan(program, state)
    candidate = Enum.fetch!(plan, length(state.evaluated))
    evaluator = evaluator(devset, optimizer, state.evaluation_max_errors)
    evaluated = evaluate_candidate(evaluator, candidate)

    %{
      state
      | evaluated: state.evaluated ++ [evaluated],
        completed_operations: state.completed_operations + 1
    }
  end

  defp advance_proposal(state, %{candidates: candidates}, _trainset)
       when candidates != [] do
    index = state.next_candidate_index
    rules = Enum.fetch!(candidates, index)

    rules_by_predictor =
      Map.new(Imp.ProgramParameters.predictors(state.baseline), &{&1.name, rules})

    row = %{
      program: apply_rules(state.baseline, rules_by_predictor),
      index: index,
      rules: rules_by_predictor,
      source: false,
      baseline: false
    }

    next = index + 1

    %{
      state
      | candidates: state.candidates ++ [row],
        next_candidate_index: next,
        proposals_complete: next == length(candidates),
        completed_operations: state.completed_operations + 1
    }
  end

  defp advance_proposal(state, optimizer, trainset) do
    rule_lm = resolve_rule_lm(optimizer, state.baseline)

    if is_nil(rule_lm) do
      error = %{
        stage: :rule_induction,
        error: "no rule LM is configured or bound to the program"
      }

      %{
        state
        | proposals_complete: true,
          proposal_errors: state.proposal_errors ++ [error],
          completed_operations: state.completed_operations + 1
      }
    else
      advance_generated_proposal(state, optimizer, trainset, rule_lm)
    end
  end

  defp advance_generated_proposal(state, optimizer, trainset, rule_lm) do
    predictors = Imp.ProgramParameters.predictors(state.baseline)

    cursor =
      state.proposal_cursor ||
        %{
          candidate_index: state.next_candidate_index,
          predictor_index: 0,
          rules: %{}
        }

    %{name: name, predictor: predictor} = Enum.fetch!(predictors, cursor.predictor_index)

    rollout_id =
      cursor.candidate_index * max(length(predictors), 1) + cursor.predictor_index

    result =
      induce_rules(
        rule_lm,
        trainset,
        predictor.signature,
        optimizer.num_rules,
        rollout_id,
        optimizer.bootstrap.teacher_settings
      )

    state = %{
      state
      | proposal_calls: state.proposal_calls + 1,
        completed_operations: state.completed_operations + 1
    }

    case result do
      {:ok, induced, attempts} ->
        rules = Map.put(cursor.rules, name, induced)
        next_predictor = cursor.predictor_index + 1
        state = %{state | proposal_attempts: state.proposal_attempts + attempts}

        if next_predictor == length(predictors) do
          row = %{
            program: apply_rules(state.baseline, rules),
            index: cursor.candidate_index,
            rules: rules,
            source: false,
            baseline: false
          }

          finish_proposal(state, cursor.candidate_index, row, optimizer.num_candidates)
        else
          %{state | proposal_cursor: %{cursor | predictor_index: next_predictor, rules: rules}}
        end

      {:error, reason, attempts} ->
        error = %{
          stage: :rule_induction,
          candidate: cursor.candidate_index,
          predictor: name,
          error: error_message(reason)
        }

        state = %{
          state
          | proposal_attempts: state.proposal_attempts + attempts,
            proposal_errors: state.proposal_errors ++ [error]
        }

        finish_proposal(state, cursor.candidate_index, nil, optimizer.num_candidates)
    end
  end

  defp finish_proposal(state, candidate_index, row, num_candidates) do
    next = candidate_index + 1
    candidates = if is_nil(row), do: state.candidates, else: state.candidates ++ [row]

    %{
      state
      | candidates: candidates,
        next_candidate_index: next,
        proposal_cursor: nil,
        proposals_complete: next == num_candidates
    }
  end

  defp evaluation_plan(program, state) do
    [
      %{program: program, index: :source, rules: %{}, source: true, baseline: false},
      %{
        program: state.baseline,
        index: :baseline,
        rules: %{},
        source: false,
        baseline: true
      }
      | state.candidates
    ]
  end

  defp run_complete?(state) do
    not is_nil(state.baseline) and state.proposals_complete and
      length(state.evaluated) == length(state.candidates) + 2
  end

  defp invocation_operation_limit(_completed, :infinity), do: :infinity
  defp invocation_operation_limit(completed, maximum), do: completed + maximum

  defp operation_budget_exhausted?(_completed, :infinity), do: false
  defp operation_budget_exhausted?(completed, limit), do: completed >= limit

  defp durable_controls?(opts) do
    not is_nil(opts[:resume_state]) or not is_nil(opts[:checkpoint_fn]) or
      opts[:max_operations] != :infinity
  end

  defp emit_checkpoint(_callback, false, _compatibility, _state), do: :ok
  defp emit_checkpoint(nil, true, _compatibility, _state), do: :ok

  defp emit_checkpoint(callback, true, compatibility, state) do
    callback.(Checkpoint.dump(compatibility, state))
    :ok
  end

  defp resume_compatibility(program, trainset, devset, optimizer, opts, metric_identity) do
    bootstrap = optimizer.bootstrap |> Map.from_struct() |> Map.drop([:metric])

    payload = %{
      datasets: %{trainset: trainset, devset: devset},
      metric: metric_identity,
      optimizer: %{
        candidates: optimizer.candidates,
        num_candidates: optimizer.num_candidates,
        num_rules: optimizer.num_rules,
        num_threads: optimizer.num_threads,
        bootstrap: runtime_identity(bootstrap),
        rule_lm: runtime_identity(resolve_rule_lm(optimizer, program))
      },
      teacher: runtime_identity(opts[:teacher]),
      program_module: program.__struct__,
      predictors:
        Enum.map(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
          %{
            name: name,
            signature: predictor.signature,
            demos: predictor.demos,
            config: predictor.config,
            lm: runtime_identity(predictor.lm),
            adapter: runtime_identity(predictor.adapter),
            dynamic_lm?: predictor.dynamic_lm?,
            dynamic_adapter?: predictor.dynamic_adapter?
          }
        end)
    }

    digest =
      payload
      |> Report.encode_term()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{"sha256" => digest}
  end

  defp runtime_identity(callback) when is_function(callback) do
    Map.new([:module, :name, :arity, :type, :uniq, :index], fn key ->
      {key, callback |> :erlang.fun_info(key) |> elem(1)}
    end)
  end

  defp runtime_identity(%_{} = struct), do: struct |> Map.from_struct() |> runtime_identity()

  defp runtime_identity(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, runtime_identity(value)} end)

  defp runtime_identity(list) when is_list(list), do: Enum.map(list, &runtime_identity/1)

  defp runtime_identity(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&runtime_identity/1) |> List.to_tuple()

  defp runtime_identity(pid) when is_pid(pid), do: :runtime_pid
  defp runtime_identity(reference) when is_reference(reference), do: :runtime_reference
  defp runtime_identity(port) when is_port(port), do: :runtime_port
  defp runtime_identity(value), do: value

  defp induce_rules(rule_lm, examples, signature, num_rules, rollout_id, teacher_settings) do
    do_induce_rules(
      rule_lm,
      examples,
      signature,
      num_rules,
      rollout_id,
      teacher_settings,
      1
    )
  end

  defp do_induce_rules(
         rule_lm,
         examples,
         signature,
         num_rules,
         rollout_id,
         teacher_settings,
         attempt
       ) do
    examples_text = format_examples(examples, signature)

    case call_rule_program(rule_lm, examples_text, num_rules, rollout_id, teacher_settings) do
      {:ok, rules} ->
        {:ok, rules, attempt}

      {:error, reason} ->
        case find_operational_safety(reason) do
          %Imp.OperationalSafetyError{} = safety ->
            raise safety

          nil ->
            if context_window_exceeded?(reason) and length(examples) > 1 do
              do_induce_rules(
                rule_lm,
                Enum.drop(examples, -1),
                signature,
                num_rules,
                rollout_id,
                teacher_settings,
                attempt + 1
              )
            else
              {:error, reason, attempt}
            end
        end
    end
  end

  defp call_rule_program(rule_lm, examples_text, num_rules, rollout_id, teacher_settings) do
    signature =
      Imp.signature(
        "examples_text -> natural_language_rules",
        "Given a set of examples, extract a list of #{num_rules} concise and non-redundant natural language rules that provide clear guidance for performing the task. All rules should be actionable for a well-specified scope of examples of this general kind of task."
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
    safety in Imp.OperationalSafetyError -> reraise safety, __STACKTRACE__
    error -> {:error, error}
  catch
    kind, reason ->
      case find_operational_safety({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> raise safety
        nil -> {:error, {kind, reason}}
      end
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

  defp context_window_exceeded?(%Imp.ContextWindowExceededError{}), do: true
  defp context_window_exceeded?({:error, reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?({:lm_failed, _lm, reason}), do: context_window_exceeded?(reason)

  defp context_window_exceeded?(%Imp.LMError{reason: reason}),
    do: context_window_exceeded?(reason)

  defp context_window_exceeded?(%{reason: reason}), do: context_window_exceeded?(reason)

  # Pinned DSPy 3.2.1 also recognizes provider exceptions whose rendered
  # class name contains `ContextWindowExceededError`. Provider adapters do not
  # all preserve a native exception type across their transport boundary, so
  # keep this deliberately narrow instead of retrying every arbitrary error as
  # upstream's broad `ValueError` branch does.
  defp context_window_exceeded?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    Enum.any?(
      [
        "contextwindowexceedederror",
        "context window exceeded",
        "context length exceeded",
        "context_length_exceeded",
        "maximum context length",
        "context overflow"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp context_window_exceeded?(_reason), do: false

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
    raise_operational_safety!(result.errors)

    if result.errors == [] do
      Map.merge(candidate, %{score: result.score, status: :ok})
    else
      Map.merge(candidate, %{score: result.score, status: :with_errors, errors: result.errors})
    end
  rescue
    safety in Imp.OperationalSafetyError ->
      reraise safety, __STACKTRACE__

    error in Imp.EvaluationCancelledError ->
      raise_operational_safety!(error.errors)
      Map.merge(candidate, %{score: nil, status: :error, error: error_message(error)})

    error ->
      Map.merge(candidate, %{score: nil, status: :error, error: error_message(error)})
  catch
    kind, reason ->
      case find_operational_safety({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety ->
          raise safety

        nil ->
          Map.merge(candidate, %{score: nil, status: :error, error: error_message({kind, reason})})
      end
  end

  defp select_best(evaluated, fallback) do
    case Enum.filter(evaluated, &(&1.status == :ok and is_number(&1.score))) do
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

  defp fetch_report!(program, optimizer) do
    report =
      [
        Imp.Optimizer.Report.fetch(program)
        | Enum.map(Imp.ProgramParameters.predictors(program), fn %{predictor: predictor} ->
            Imp.Optimizer.Report.fetch(predictor)
          end)
      ]
      |> Enum.find(fn
        %{optimizer: ^optimizer} -> true
        _other -> false
      end)

    report || raise "InferRules expected #{optimizer} to attach an optimizer report"
  end

  defp attach_report(program, report) do
    case Imp.ProgramAccess.predict(program) do
      nil ->
        Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
          Imp.ProgramParameters.update_predictor(
            acc,
            name,
            &Imp.Optimizer.Report.attach(&1, report)
          )
        end)

      _predictor ->
        Imp.Optimizer.Report.attach(program, report)
    end
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

  defp raise_operational_safety!(value) do
    case find_operational_safety(value) do
      %Imp.OperationalSafetyError{} = safety -> raise safety
      nil -> :ok
    end
  end

  defp find_operational_safety(%Imp.OperationalSafetyError{} = error), do: error

  defp find_operational_safety(%_{} = struct),
    do: struct |> Map.from_struct() |> find_operational_safety()

  defp find_operational_safety(map) when is_map(map) do
    Enum.find_value(map, fn {_key, value} -> find_operational_safety(value) end)
  end

  defp find_operational_safety(list) when is_list(list),
    do: Enum.find_value(list, &find_operational_safety/1)

  defp find_operational_safety(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.find_value(&find_operational_safety/1)

  defp find_operational_safety(_value), do: nil
end
