defmodule Imp.Optimizer.MIPROv2.UpstreamProposer do
  @moduledoc false

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
  @instruction_generator "Use the information below to learn about a task that we are trying to solve using calls to an LM, then generate a new instruction that will be used to prompt a Language Model to better solve the task."

  def summarize!(lm, trainset, signature, batch_size) do
    batches = trainset |> Enum.chunk_every(batch_size) |> Enum.take(10)

    [first | rest] =
      case batches do
        [] ->
          raise ArgumentError, "DSPy 3.2.1 MIPRO dataset summary requires a non-empty trainset"

        batches ->
          batches
      end

    observations =
      call!(lm, dataset_descriptor_signature(), %{examples: examples_repr(first, signature)},
        temperature: 1.0
      )
      |> Imp.get(:observations)

    {observations, _skips} =
      Enum.reduce_while(rest, {observations, 0}, fn batch, {accumulated, skips} ->
        next =
          call!(
            lm,
            dataset_descriptor_with_prior_signature(),
            %{examples: examples_repr(batch, signature), prior_observations: accumulated},
            temperature: 1.0
          )
          |> Imp.get(:observations)

        if String.starts_with?(String.upcase(next), "COMPLETE") do
          skips = skips + 1
          if skips >= 5, do: {:halt, {accumulated, skips}}, else: {:cont, {accumulated, skips}}
        else
          {:cont, {accumulated <> next, skips}}
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

    unless is_integer(count) and count > 0 do
      raise ArgumentError, "DSPy 3.2.1 MIPRO proposer count must be a positive integer"
    end

    {instructions, slots, _rng} =
      Enum.reduce(0..(count - 1), {[], [], rng}, fn index, {instructions, slots, rng} ->
        {tip, rng} = PythonRandom.choice(rng, @tips)
        {rollout_id, rng} = PythonRandom.randint(rng, 0, 1_000_000_000)

        prediction =
          call!(
            lm,
            instruction_generator_signature(tip != ""),
            %{
              dataset_description: dataset_summary,
              task_demos: "No task demos provided.",
              basic_instruction: predictor.signature.instructions,
              tip: tip
            },
            rollout_id: rollout_id,
            temperature: Keyword.fetch!(opts, :temperature)
          )

        instruction = prediction |> Imp.get(:proposed_instruction) |> strip_prefix()
        slot = %{proposal_index: index, rollout_id: rollout_id, tip: tip}
        {instructions ++ [instruction], slots ++ [slot], rng}
      end)

    {instructions,
     %{
       status: :ok,
       calls: count,
       errors: [],
       slots: slots,
       fidelity: :dspy_3_2_1,
       upstream_release: "DSPy 3.2.1",
       upstream_commit: "29448ae12756abdd14bd8796c819247ebb83673c"
     }, rng}
  end

  defp call!(lm, signature, inputs, opts) do
    messages = Imp.Adapter.Chat.format(signature, inputs, response_instruction: true)

    raw =
      case Imp.LM.generate(lm, messages, opts) |> Imp.LM.Result.unwrap() do
        {:ok, raw} -> raw
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

  defp instruction_generator_signature(use_tip?) do
    inputs = [
      %{name: :dataset_description, desc: "A description of the dataset that we are using."},
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

  defp examples_repr(examples, signature) do
    "[" <> Enum.map_join(examples, ", ", &example_repr(&1, signature)) <> "]"
  end

  defp example_repr(%Imp.Example{} = example, signature) do
    present = MapSet.new(Imp.Example.keys(example))

    fields =
      (signature.inputs ++ signature.outputs)
      |> Enum.filter(&MapSet.member?(present, &1.name))
      |> Enum.map(&{&1.name, Imp.Example.get(example, &1.name)})

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
