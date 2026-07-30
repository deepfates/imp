defmodule Imp.Optimizer.MIPROv2.UpstreamProposer do
  @moduledoc false

  alias Imp.OperationalSafetyError
  alias Imp.Optimizer.MIPROv2.PythonRandom

  @tips [
    "",
    "Don't be afraid to be creative when creating the new instruction!",
    "Keep the instruction clear and concise.",
    "Make sure your instruction is very informative and descriptive.",
    "The instruction should include a high stakes scenario in which the LM must solve the task!",
    "Include a persona that is relevant to the task in the instruction (ie. \"You are a ...\")"
  ]

  @dataset_descriptor "Given several examples from a dataset please write observations about trends that hold for most or all of the samples. Some areas you may consider in your observations: topics, content, syntax, conciseness, etc. It will be useful to make an educated guess as to the nature of the task this dataset will enable. Don't be afraid to be creative"
  @dataset_descriptor_with_prior "Given several examples from a dataset please write observations about trends that hold for most or all of the samples. I will also provide you with a few observations I have already made.  Please add your own observations or if you feel the observations are comprehensive say 'COMPLETE' Some areas you may consider in your observations: topics, content, syntax, conciceness, etc. It will be useful to make an educated guess as to the nature of the task this dataset will enable. Don't be afraid to be creative"
  @observation_summarizer "Given a series of observations I have made about my dataset, please summarize them into a brief 2-3 sentence summary which highlights only the most important details."
  @describe_program "Below is some pseudo-code for a pipeline that solves tasks with calls to language models. Please describe what type of task this program appears to be designed to solve, and how it appears to work."
  @describe_module "Below is some pseudo-code for a pipeline that solves tasks with calls to language models. Please describe the purpose of one of the specified module in this pipeline."
  @instruction_generator "Use the information below to learn about a task that we are trying to solve using calls to an LM, then generate a new instruction that will be used to prompt a Language Model to better solve the task."

  def summarize!(lm, trainset, batch_size) do
    batches = trainset |> Enum.chunk_every(batch_size) |> Enum.take(10)

    [first | rest] =
      case batches do
        [] ->
          raise ArgumentError, "DSPy 3.2.1 MIPRO dataset summary requires a non-empty trainset"

        batches ->
          batches
      end

    observations =
      call!(lm, dataset_descriptor_signature(), %{examples: examples_repr(first)},
        temperature: 1.0
      )
      |> Imp.get(:observations)

    {observations, _skips} =
      Enum.reduce_while(rest, {observations, 0}, fn batch, {accumulated, skips} ->
        try do
          next =
            call!(
              lm,
              dataset_descriptor_with_prior_signature(),
              %{examples: examples_repr(batch), prior_observations: accumulated},
              temperature: 1.0
            )
            |> Imp.get(:observations)

          if String.starts_with?(String.upcase(next), "COMPLETE") do
            skips = skips + 1

            if skips >= 5,
              do: {:halt, {accumulated, skips}},
              else: {:cont, {accumulated, skips}}
          else
            {:cont, {accumulated <> next, skips}}
          end
        rescue
          safety in OperationalSafetyError -> reraise safety, __STACKTRACE__
          _ordinary_continuation_failure -> {:halt, {accumulated, skips}}
        end
      end)

    call!(lm, observation_summarizer_signature(), %{observations: observations}, temperature: 1.0)
    |> Imp.get(:summary)
    |> strip_prefix()
  end

  def propose_with_report!(lm, predictor, dataset_summary, opts) do
    seed = Keyword.fetch!(opts, :seed)

    {instructions, report, _rng} =
      propose_with_report_and_rng!(lm, predictor, dataset_summary, PythonRandom.new(seed), opts)

    {instructions, report}
  end

  def propose_with_report_and_rng!(lm, predictor, dataset_summary, rng, opts) do
    count = Keyword.fetch!(opts, :count)
    demo_sets = Keyword.get(opts, :demo_sets, [])
    fewshot_aware? = Keyword.get(opts, :fewshot_aware, false)
    program_aware? = Keyword.get(opts, :program_aware, false)
    program_code = Keyword.get(opts, :program_code)

    unless is_integer(count) and count > 0 do
      raise ArgumentError, "DSPy 3.2.1 MIPRO proposer count must be a positive integer"
    end

    {instructions, slots, rng} =
      Enum.reduce(0..(count - 1), {[], [], rng}, fn index, {instructions, slots, rng} ->
        {tip, rng} = PythonRandom.choice(rng, @tips)
        {rollout_id, rng} = PythonRandom.randint(rng, 0, 1_000_000_000)

        task_demos = task_demos(predictor, demo_sets, index, fewshot_aware?)

        {program_inputs, program_context_error, program_context_calls} =
          program_inputs!(
            lm,
            predictor,
            task_demos,
            program_code,
            program_aware?,
            rollout_id,
            Keyword.fetch!(opts, :temperature)
          )

        prediction =
          call!(
            lm,
            instruction_generator_signature(tip != "", program_aware?),
            Map.merge(program_inputs, %{
              dataset_description: dataset_summary,
              task_demos: task_demos,
              basic_instruction: predictor.signature.instructions,
              tip: tip
            }),
            rollout_id: rollout_id,
            temperature: Keyword.fetch!(opts, :temperature)
          )

        instruction = prediction |> Imp.get(:proposed_instruction) |> strip_prefix()

        slot = %{
          proposal_index: index,
          demo_set_index: index,
          grounded_demo_count: grounded_demo_count(demo_sets, index, fewshot_aware?),
          program_aware: program_aware?,
          program_context_calls: program_context_calls,
          program_context_error: program_context_error,
          rollout_id: rollout_id,
          tip: tip
        }

        {instructions ++ [instruction], slots ++ [slot], rng}
      end)

    errors =
      for %{proposal_index: index, program_context_error: error} <- slots,
          not is_nil(error),
          do: {:program_context_error, index, error}

    {instructions,
     %{
       status: if(errors == [], do: :ok, else: :with_program_context_errors),
       calls: count + Enum.sum(Enum.map(slots, & &1.program_context_calls)),
       candidate_count: count,
       errors: errors,
       slots: slots,
       program_aware: program_aware?,
       fidelity: :dspy_3_2_1,
       upstream_release: "DSPy 3.2.1",
       upstream_commit: "29448ae12756abdd14bd8796c819247ebb83673c"
     }, rng}
  end

  defp task_demos(_predictor, _demo_sets, _index, false), do: "No task demos provided."
  defp task_demos(_predictor, _demo_sets, 0, true), do: "No task demos provided."

  defp task_demos(predictor, demo_sets, index, true) do
    case grounded_demos(demo_sets, index) do
      [] ->
        "No task demos provided."

      demos ->
        Enum.map_join(demos, "\n\n", &example_string(predictor.signature, &1)) <> "\n\n"
    end
  end

  defp grounded_demo_count(_demo_sets, _index, false), do: 0
  defp grounded_demo_count(demo_sets, index, true), do: length(grounded_demos(demo_sets, index))

  defp grounded_demos(demo_sets, index) do
    Imp.Optimizer.InstructionProposer.grounded_augmented_demos(demo_sets, index, 3)
  end

  defp example_string(signature, example) do
    (signature.inputs ++ signature.outputs)
    |> Enum.map_join("\n", fn field ->
      "#{field.prefix} #{python_str(Imp.Example.get(example, field.name))}"
    end)
  end

  defp python_str(nil), do: "None"
  defp python_str(true), do: "True"
  defp python_str(false), do: "False"
  defp python_str(value) when is_binary(value), do: value
  defp python_str(value) when is_number(value), do: to_string(value)
  defp python_str(value), do: inspect(value)

  defp program_inputs!(
         _lm,
         _predictor,
         _task_demos,
         _program_code,
         false,
         _rollout_id,
         _temperature
       ),
       do: {%{}, nil, 0}

  defp program_inputs!(lm, predictor, task_demos, program_code, true, rollout_id, temperature)
       when is_binary(program_code) do
    defaults = %{
      program_code: program_code,
      program_description: "Not available",
      module: "Not provided",
      module_description: "Not provided"
    }

    try do
      program_description =
        call!(
          lm,
          describe_program_signature(),
          %{program_code: program_code, program_example: task_demos},
          rollout_id: rollout_id,
          temperature: temperature
        )
        |> Imp.get(:program_description)
        |> strip_prefix()

      module = module_code(predictor)
      described = %{defaults | program_description: program_description, module: module}

      try do
        module_description =
          call!(
            lm,
            describe_module_signature(),
            %{
              program_code: program_code,
              program_example: task_demos,
              program_description: program_description,
              module: module
            },
            rollout_id: rollout_id,
            temperature: temperature,
            max_depth: 10
          )
          |> Imp.get(:module_description)
          |> strip_prefix()

        {%{described | module_description: module_description}, nil, 2}
      rescue
        safety in OperationalSafetyError -> reraise safety, __STACKTRACE__
        error -> {described, Exception.message(error), 2}
      end
    rescue
      safety in OperationalSafetyError -> reraise safety, __STACKTRACE__
      error -> {defaults, Exception.message(error), 1}
    end
  end

  defp program_inputs!(
         _lm,
         _predictor,
         _task_demos,
         _program_code,
         true,
         _rollout_id,
         _temperature
       ) do
    raise ArgumentError,
          "DSPy 3.2.1 program-aware MIPRO proposals require explicit program source text"
  end

  defp module_code(predictor) do
    inputs = Enum.map_join(predictor.signature.inputs, ", ", &to_string(&1.name))
    outputs = Enum.map_join(predictor.signature.outputs, ", ", &to_string(&1.name))
    "Predict(#{inputs}) -> #{outputs}"
  end

  defp call!(lm, signature, inputs, opts) do
    messages = Imp.Adapter.Chat.format(signature, inputs, response_instruction: true)

    raw =
      case Imp.LM.generate(lm, messages, opts) |> Imp.LM.Result.unwrap() do
        {:ok, raw} -> raw
        {:error, %OperationalSafetyError{} = safety} -> raise safety
        {:error, reason} -> raise "DSPy 3.2.1 MIPRO proposer LM call failed: #{inspect(reason)}"
      end

    case Imp.Adapter.Chat.parse(signature, raw, []) do
      {:ok, prediction} ->
        prediction

      {:error, reason} ->
        raise "DSPy 3.2.1 MIPRO proposer output failed to parse: #{inspect(reason)}"
    end
  end

  defp dataset_descriptor_signature do
    signature(
      @dataset_descriptor,
      [%{name: :examples, desc: "Sample data points from the dataset"}],
      [
        %{
          name: :observations,
          desc: "Somethings that holds true for most or all of the data you observed"
        }
      ]
    )
  end

  defp dataset_descriptor_with_prior_signature do
    signature(
      @dataset_descriptor_with_prior,
      [
        %{name: :examples, desc: "Sample data points from the dataset"},
        %{name: :prior_observations, desc: "Some prior observations I made about the data"}
      ],
      [
        %{
          name: :observations,
          desc:
            "Somethings that holds true for most or all of the data you observed or COMPLETE if you have nothing to add"
        }
      ]
    )
  end

  defp observation_summarizer_signature do
    signature(
      @observation_summarizer,
      [%{name: :observations, desc: "Observations I have made about my dataset"}],
      [
        %{
          name: :summary,
          desc:
            "Two to Three sentence summary of only the most significant highlights of my observations"
        }
      ]
    )
  end

  defp describe_program_signature do
    signature(
      @describe_program,
      [
        %{
          name: :program_code,
          desc: "Pseudocode for a language model program designed to solve a particular task."
        },
        %{name: :program_example, desc: "An example of the program in use."}
      ],
      [
        %{
          name: :program_description,
          desc:
            "Describe what task the program is designed to solve, and how it goes about solving this task."
        }
      ]
    )
  end

  defp describe_module_signature do
    signature(
      @describe_module,
      [
        %{
          name: :program_code,
          desc: "Pseudocode for a language model program designed to solve a particular task."
        },
        %{name: :program_example, desc: "An example of the program in use."},
        %{
          name: :program_description,
          desc:
            "Summary of the task the program is designed to solve, and how it goes about solving it."
        },
        %{name: :module, desc: "The module in the program that we want to describe."}
      ],
      [
        %{
          name: :module_description,
          desc: "Description of the module's role in the broader program."
        }
      ]
    )
  end

  defp instruction_generator_signature(use_tip?, program_aware?) do
    inputs = [
      %{name: :dataset_description, desc: "A description of the dataset that we are using."}
    ]

    inputs =
      if program_aware? do
        inputs ++
          [
            %{
              name: :program_code,
              desc: "Language model program designed to solve a particular task."
            },
            %{
              name: :program_description,
              desc:
                "Summary of the task the program is designed to solve, and how it goes about solving it."
            },
            %{name: :module, desc: "The module to create an instruction for."},
            %{
              name: :module_description,
              desc: "Description of the module to create an instruction for."
            }
          ]
      else
        inputs
      end

    inputs =
      inputs ++
        [
          %{name: :task_demos, desc: "Example inputs/outputs of our module."},
          %{name: :basic_instruction, desc: "Basic instruction."}
        ]

    inputs =
      if use_tip?,
        do:
          inputs ++
            [
              %{
                name: :tip,
                desc: "A suggestion for how to go about generating the new instruction."
              }
            ],
        else: inputs

    signature(
      @instruction_generator,
      inputs,
      [
        %{
          name: :proposed_instruction,
          desc:
            "Propose an instruction that will be used to prompt a Language Model to perform this task."
        }
      ]
    )
  end

  defp signature(instructions, inputs, outputs),
    do: Imp.signature(%{instructions: instructions, inputs: inputs, outputs: outputs})

  defp examples_repr(examples) do
    "[" <> Enum.map_join(examples, ", ", &example_repr/1) <> "]"
  end

  # DSPy summarizes the Example values supplied by the consumer; it does not
  # require a program-level signature. That distinction matters for ordinary
  # multi-predictor programs, whose external task contract is not any one
  # predictor signature. Imp maps do not retain Python insertion order, so the
  # stable BEAM representation is explicit inputs first, followed by the other
  # public fields in lexical order. Example.keys/1 deliberately omits `imp_`
  # fields, keeping recorder identities and metric-owned rows out of proposals.
  defp example_repr(%Imp.Example{} = example) do
    public_keys = Imp.Example.keys(example)
    present = MapSet.new(public_keys)

    input_keys =
      example.input_keys
      |> List.wrap()
      |> Enum.filter(&MapSet.member?(present, &1))

    input_set = MapSet.new(input_keys)

    remaining_keys =
      public_keys
      |> Enum.reject(&MapSet.member?(input_set, &1))
      |> Enum.sort_by(&to_string/1)

    fields =
      Enum.map(input_keys ++ remaining_keys, &{&1, Imp.Example.get(example, &1)})

    body =
      Enum.map_join(fields, ", ", fn {key, value} ->
        "#{py_repr(to_string(key))}: #{py_repr(value)}"
      end)

    inputs =
      example.input_keys
      |> List.wrap()
      |> Enum.map(&py_repr(to_string(&1)))
      |> Enum.sort()
      |> Enum.join(", ")

    "Example({#{body}}) (input_keys={#{inputs}})"
  end

  defp py_repr(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'" <> escaped <> "'"
  end

  defp py_repr(nil), do: "None"
  defp py_repr(true), do: "True"
  defp py_repr(false), do: "False"
  defp py_repr(value) when is_number(value), do: to_string(value)
  defp py_repr(value), do: value |> to_string() |> py_repr()

  defp strip_prefix(text) do
    Regex.replace(~r/^[*\s]*(([\w'\-]+\s+){0,4}[\w'\-]+):\s*/u, text, "")
    |> String.trim("\"")
  end
end
